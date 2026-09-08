# Stage 4, S4-4: documentation on your own page — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S4-4 of `docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md` (§5's S4-4 row, decision **D3**). A maker writes their README **in the app**, on the README card S4-1 put at the top of Files, for **any** project — with a template when there is none and the no-history trade named on the editor itself. They **preview** their own public page at any visibility, in the app shell, behind a banner. They publish from a **Publish panel** on the project page: three visibility rows with plain-language meanings, a licence, an inline handle claim, the URL with Copy, the unlisted link with Copy and New link. And a README's headings keep their `id` through the sanitizer, so a link into one resolves.

**Stories moved:** 5.1, 5.2, 5.3, 5.4 (the anchors half), 5.8. **Not 2.13** — see decision 7 below.

**Architecture:** the save primitives `FilesController#update` already uses move into one service, `Maker::TextSave`, and the README door calls the same one: the `base_token` 409, `Maker::Addons::LibraryOutput.write_bytes!(..., replace: true)` (the port, reusing the node), and a `Maker::RepoEdit` when the folder is a working tree. The README door takes **no node id from the client** — it resolves the row from the project's own listing through `Maker::Readme.row_in`, which is what confines D3's exception to documentation structurally rather than by a name check. The preview is `ProjectsController#preview`, session-authed, rendering a new `public/projects/_page.html.erb` — extracted from `public/projects/show.html.erb` so the two pages cannot drift — over a `Maker::PublicProject` built for the owner; `Public::BaseController` is untouched. The Publish panel is the ONE place visibility and licence are set: they leave `projects/_form.html.erb` rather than existing twice. Heading anchors are a Nokogiri pass inside `Maker::Markdown` that drops every `id` a heading did not carry and normalises the survivors to `[a-z0-9-]`, before `sanitize` sees them.

**Tech Stack:** Rails 8, Hotwire, the **existing** vendored CodeMirror bundle (it already exports `markdown` — `vendor/javascript/codemirror-entry.js:26` — and `languageFor("md")` already returns `cm.markdown()` at `app/javascript/lib/codemirror_languages.js:39`, so **no new pin, no rebuild, no `bin/build-codemirror` run**), Minitest, `page_query_budget_test.rb`, `template_hygiene_test.rb`, `stimulus_hygiene_test.rb`, `css_hygiene_test.rb`.

---

## Decisions recorded here, not in the tasks — these are settled; do not re-derive them

1. **The editor is a real form that redirects, not a JSON fetch.** `editor_controller.js` PATCHes JSON because the file page must stay put and roll its token forward for a second save. The README editor's whole point is *seeing it rendered on your own page* (story 5.3), so a plain `form_with` → `PATCH /projects/:id/readme` → `redirect_to project_path` gives the story's payoff for free and needs no JSON error surface, no token roll-forward and no Turbo Stream. `readme_controller.js` only upgrades the textarea to CodeMirror and copies the buffer back on submit.
2. **The editor is lazy behind a `<details>`, and the textarea starts `disabled`.** Reading the README's bytes for every project page render is a port read nobody asked for; the fetch happens on the first `toggle` when open (`modelviewer_controller.js`'s `lazy` argument). The textarea and the Save button are rendered `disabled` and enabled only once the buffer holds the real bytes — **without that, a failed bundle load plus a click on Save would blank the README**. The server refuses a blank body as well, so the defence is not JavaScript's alone.
3. **The door takes no node id.** `Projects::ReadmesController#update` resolves the README from `Maker::Readme.row_in(listing.loose)` — the same call both cards render from. A client cannot name a file, so D3's exception cannot be widened by a hand-crafted request; the "Markdown files only" limit is structural rather than a predicate someone can loosen.
4. **The preview renders the visitor's page with the visitor's URLs, inside the APP shell.** `Maker::PublicProject#file_url_for` stays the ONE answer to "where does this file's link point" (that class exists so the page and the file route cannot disagree), so the preview does not rewrite links to `/files/:id`. For an **unlisted or public** project the links work identically for the owner and for a visitor — the case a maker previews for. For a **private** project they 404, which is what a visitor gets, and the banner says so in as many words. Rewriting them to private paths would make the preview show something no visitor can see, which is the opposite of its job.
5. **A preview needs a handle, and refuses without one.** Every URL on the page is `/u/<handle>/<slug>`; with no handle `public_file_path(nil, …)` raises `ActionController::UrlGenerationError` against the route's own `[a-z0-9][a-z0-9-]*` constraint. `Maker::Project#publishing_needs_a_handle` already refuses to publish without one, so refusing to preview is the same rule, and the Publish panel's inline claim is the door. `#preview` redirects to the project page with an alert naming it.
6. **Visibility and licence MOVE out of `projects/_form.html.erb` into the panel.** Two controls for one column is the "one question with two answers" shape §14a keeps recording; the panel is also the only one of the two that can carry the plain-language meanings §5's S4-4 row asks for, and the form's "choose a handle first" hint duplicates the panel's inline claim. `project_params` still permits both — the panel posts to the same `ProjectsController#update`. `project_publishing_form_test.rb`'s two rendered-field tests and its two hint tests move to `publishing_test.rb` with the panel; its three save/badge tests stay where they are and stay green.
7. **Story 2.13 is NOT moved, and `FilesController` is NOT widened.** D3's prose says "Markdown is editable anywhere" and names 2.13, but §5's S4-4 row — the authority for what a slice moves — lists 5.1, 5.2, 5.3, 5.4 and 5.8 only. Widening `FilesController#update` to any `.md` outside a repository is a second door with its own surfaces (the file page's editor, its no-history note, its thumbnail staleness) and belongs to a slice that names 2.13. `docs/invariants/git-editing.md`'s new paragraph therefore describes the **README door only** and says in as many words that a wider relaxation needs its own spec.
8. **The panel is the LAST secondary panel, with a `Publish` link in the page head.** The head already carries the visibility badge and the "Public page" link, so that is where a maker already looks for publishing state; a settings box above the maker's own content on every render would give a `built-unused` surface prime real estate, which spec §2.3 forbids. The head link is a plain `<a href="#publish">` — no JS.
9. **`copy_controller.js` is created HERE if it does not exist.** S4-3's plan creates the same controller. Whichever slice lands first creates it; the second reuses it unchanged. **If `app/javascript/controllers/copy_controller.js` already exists when you start, skip its step and do not edit it** — it is the same three lines either way, and two versions of it is the drift. Say in the commit message which happened.
10. **`page_query_budget_test.rb`'s public seed is extracted into a helper** so the new `projects#preview` budget measures the same growth the public page's does. A second copy of that 65-line fixture is a pair that drifts, and the preview would then be budgeted against a shape the public page no longer has.

---

## Amendments (orchestrator review, 2026-09-07) — the open questions, decided

1. **`readme_controller.js#sync` GETS A SYSTEM TEST, in this slice.** A save path whose deletion
   leaves the suite green is this repo's dominant failure shape (§15), and Chrome is available.
   Add `test/system/readme_editor_test.rb`: open the editor on a share-library project with a real
   README, type into the CodeMirror content (`find(".cm-content").send_keys(...)` or
   `execute_script` on the view), Save, and assert the rendered `.markdown` shows the new text and
   the file on disk holds it. Mutation: empty `sync`'s body → the test must go red. Report both runs.
2. **A private project's preview keeps the visitor's URLs**, dead for its owner, with the banner
   saying so. Accepted as the plan argues.
3. **The Publish panel is the LAST panel**, with a `#publish` link in the page head. Accepted.
4. **Move only the tests whose SUBJECT moved.** Visibility and licence leave `_form`, so the
   tests that posted them through the form move to `publishing_test.rb`; every other test in
   `project_publishing_form_test.rb` stays where it is.
5. **`copy_controller.js` is S4-3's.** S4-3 lands before this slice by the overview's order, so
   this plan REUSES it and creates nothing; if the order changes, the plan that lands first creates
   it and the other reuses — never two copies.

Everything else stands as written. When a step below conflicts with an amendment, the amendment wins.

## Before you start

- Branch from `main` (S4-3 merged, `732593f`; S4-1, S4-2 and S4-3 are all on `main`, and no other slice is being implemented in this worktree). Never push to `main`. **Line numbers quoted in this plan were measured before S4-2 and S4-3 landed and have drifted** (`EDITABLE_MAX_BYTES` is at `files_controller.rb:1415` now, not `:1354`); anchor every edit on the quoted TEXT, never on a line number. `_attachments.html.erb`'s card slot is anchored on the text `<%# THE ROOT'S CARD (stage 4, S4-1)`. `app/javascript/controllers/copy_controller.js` EXISTS (S4-3 created it) — amendment 5 applies: reuse it, create nothing, edit nothing.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; from a worktree `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci`. The three backend legs (`test`, `test-s3`, `test-chunk-remote`) must report identical run counts.
- **Read first, in full:** `docs/invariants/git-editing.md` — every rule, and especially the first ("Bytes the catalog tracks go through the port; bytes git owns never do", `:28-45`), "Restore writes a pending edit and never commits" (`:266-281`), "A truncated buffer is never editable, and the SERVER is what enforces it" (`:112-119`) and "A `.lock` file is refused, never deleted" (`:100-111`). You are carving ONE exception out of this file's "no repository, no editing" rule and keeping every other rule intact. Then CLAUDE.md **§14a**'s `write(..., replace: true)` bullet (the replace must REUSE the node; `LibraryOutput#existing_at` resolves "the file being replaced" by `(parent, name)` on chunk_remote and by `storage_path` on share/s3), **§14d** (`Public::` stands on `ActionController::Base` and never reads the session; CodeMirror is ONE bundle and exactly one importmap pin — **never `bin/importmap pin @codemirror/*`**; a `data-controller` that resolves to nothing is a SILENT no-op; the `form_with` `scope:` rule; an ERB comment ends at its first `%>`), `docs/invariants/design-system.md` (a component selector is defined in `components.css` only — everything this slice adds is a page modifier in `pages/projects.css`; `vendor-overrides.css` is the one unlayered sheet and the CodeMirror skin already lives there, so **this slice adds nothing to it**), and `docs/invariants/files-preview.md`'s "Extensionless text is a SEPARATE AXIS" (`:424`).
- **Facts verified by reading, that you will rely on:**
  - `Maker::Readme::NAMES = %w[README.md README.markdown README.txt README readme.md Readme.md]` and `Maker::Readme.row_in(rows)` is the ONE definition of "which row is the README" (`app/services/maker/readme.rb:37,57-59`). Root-only and case-sensitive; this slice does not widen it.
  - `ProjectsController#show` already builds `@root_card` (root working tree) **or** `@readme` (plain folder) from **the same rows**, `@listing.loose` (`app/controllers/projects_controller.rb:180-193`). `Maker::RepoCard.for` reads `dir.files`, which for the root card IS `@listing.loose` (`:186`).
  - `Maker::ProjectFolderListing#root_repo?` is in memory, no query (`app/services/maker/project_folder_listing.rb:132`).
  - `Maker::Addons::LibraryOutput.write_bytes!(user, parent_node_id:, name:, bytes:, replace: false)` is the ONE `port_writable?` branch and returns a `node_id`. With `replace: false` and a free name it CREATES on every backend: share/s3 through `FileLayer#write`, chunk_remote through `begin_upload`/`put_chunk`/`finalize_upload` with `node_id: nil` (`app/services/maker/addons/library_output.rb:75-79,148-176`). With a name already taken it raises `FileLayer::UnsupportedOperation` — the clobber refusal (§14a).
  - `FilesController::EDITABLE_MAX_BYTES = 200_000` (`app/controllers/files_controller.rb:1354`); `editor_controller.js`'s `MAX_BYTES` is the courteous half of the same rule. Read the constant, never copy the number.
  - `Maker::PublicProject.new(project)` takes the project alone, reads `project.user`, and consults no session anywhere (`app/services/maker/public_project.rb:43-50`). It can therefore be built for a PRIVATE project by its owner with no change to `Public::BaseController`.
  - `ShellHelper::SECTIONS` maps `controller_path`'s FIRST segment (`app/helpers/shell_helper.rb:80-83`). `projects/readmes` and `projects/unlisted_tokens` both resolve to `projects`, and `#preview` is an action on `ProjectsController` — so **no `SECTIONS` entry is needed and none must be added**; `rail_section` stays `projects` for all three.
  - kramdown emits heading ids already and the sanitizer strips them today. **Probed** (`bundle exec ruby`, kramdown + kramdown-parser-gfm, 2026-09-07): `# Desk Lamp` → `<h1 id="desk-lamp">`; `### Bill of Materials (v2)` → `id="bill-of-materials-v2"`; `## Unicode ü & Symbols!` → `id="unicode-ü--symbols"` (a non-`[a-z0-9-]` character and a double hyphen survive kramdown); a block IAL (`{: #para-ial}`) puts an `id` on a **`<p>`**; raw HTML `<h2 id="raw-one">` and `<p id="pid">` pass through verbatim. So allowing `id` globally in `ALLOWED_ATTRS` is not enough and not safe — the pass in Task A is what makes it both.
  - `test/services/maker/markdown_test.rb:16` asserts `%r{<h1>Title</h1>}`. Allowing ids **breaks that assertion**; Task A updates it.
  - `test/integration/web/template_hygiene_test.rb` fails if any `app/views/**/*.erb` is rendered by no page in its `pages` hash (the coverage diff at `:423-451`). Every new template here must be reached.
  - `test/system/shell_test.rb`'s phone sweep has two loops: a signed-in array (`:273-282`) and a public hash (`:332-340`). A branch gated on a path match needs a boolean asserted after the loop (`launched_gerber`, `opened_repo` at `:308-309`) — the file's own rule.
- Fixtures: a project folder in a request test is `project_folder_rows!(user, project)` — never `ensure_library_folder!` (a real mkdir; red on s3 and chunk_remote). **A test that writes real README bytes owns a share library**: `setup { @library = use_fresh_share_library! }` plus `Library::ScanJob.new.perform(user_id: user.id)`, the idiom `test/integration/web/project_repo_card_test.rb:16,33-56` carries. A published-project fixture is `PublicFixture#make_owner!` + `#seed_public_project!` (`test/support/public_fixture.rb`).
- `git add` a new file before a mutation check; restore with `git checkout -- <file>`; clear `tmp/cache/bootsnap*` after an equal-length restore; `git status --porcelain` before the next run.

## File structure

| path | responsibility | task |
|---|---|---|
| `app/services/maker/markdown.rb`, `test/services/maker/markdown_test.rb` | heading anchors survive, sanitised; every other `id` is dropped | **A** |
| new `app/services/maker/text_save.rb`, `app/controllers/files_controller.rb#update`, new `test/services/maker/text_save_test.rb`, `test/integration/web/repo_edit_flow_test.rb` | the ONE text save both doors call | **B** |
| `docs/invariants/git-editing.md` | the Markdown exception, argued | **G** |
| `config/routes.rb` (readme), new `app/controllers/projects/readmes_controller.rb`, `app/controllers/projects_controller.rb#show` (`@readme_row`, `@readme_editable`), new `app/javascript/controllers/readme_controller.js`, new `app/views/projects/_readme_editor.html.erb`, new `app/views/shared/_no_history_note.html.erb`, `app/views/projects/_readme_card.html.erb`, `_repo_card.html.erb`, `_file_tree_section.html.erb`, `_attachments.html.erb`, `app/assets/stylesheets/pages/projects.css`, `app/services/maker/readme.rb` (`template_for`); new `test/integration/web/readme_edit_test.rb`, `test/services/maker/readme_test.rb` | the README editor | **C** |
| `config/routes.rb` (preview), `app/controllers/projects_controller.rb#preview`, new `app/views/projects/preview.html.erb`, new `_preview_banner.html.erb`, new `app/views/public/projects/_page.html.erb`, `app/views/public/projects/show.html.erb`, `app/assets/stylesheets/pages/projects.css`; new `test/integration/web/project_preview_test.rb` | the owner preview | **D** |
| `config/routes.rb` (unlisted_token), new `app/controllers/projects/unlisted_tokens_controller.rb`, `app/controllers/projects_controller.rb#update`, `app/controllers/settings/handles_controller.rb`, new `app/views/projects/_publish.html.erb`, `app/views/projects/show.html.erb`, `_form.html.erb`, new `app/javascript/controllers/copy_controller.js`, `app/assets/stylesheets/pages/projects.css`; new `test/integration/web/publishing_test.rb`, `test/integration/web/project_publishing_form_test.rb`, `test/integration/web/settings_handle_test.rb` | the Publish panel | **E** |
| `test/integration/web/template_hygiene_test.rb`, `test/integration/web/page_query_budget_test.rb`, `test/system/shell_test.rb` | the cross-cutting guards | **F** |
| `docs/user-stories.md` (re-tag 5.1, 5.2, 5.3, 5.4, 5.8), `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md` (S4-4 row) | close-out | **H** |

**Dependencies and batches.**

1. **A, B and G in parallel** — three disjoint file sets, no shared test file.
2. **C** — after B (`Projects::ReadmesController` calls `Maker::TextSave`).
3. **D** — after C.
4. **E** — after D.
5. **F**, then **H**.

**Why C, D and E are serial.** Not because their behaviour is coupled — it is not — but because all three edit `config/routes.rb`, `app/controllers/projects_controller.rb` and `app/assets/stylesheets/pages/projects.css`. Parallel agents editing one file in one worktree is a recorded hazard (memory: `parallel-agents-one-worktree-rules`), and three three-line edits are not worth the loss. E additionally needs `preview_project_path`, which D creates.

---

### Task A: heading anchors survive the sanitizer

**Files:**
- Modify: `app/services/maker/markdown.rb`
- Test: `test/services/maker/markdown_test.rb`

- [ ] **Step 1: the failing tests.** Append to `test/services/maker/markdown_test.rb`:

```ruby
  # STAGE 4, S4-4 (story 5.4): a README's headings keep their anchor, so `#build-steps` in a link
  # — or in the URL a reader was handed — lands somewhere. kramdown has always emitted these ids;
  # ALLOWED_ATTRS is what dropped them, and the pass this test pins is what makes allowing them
  # safe rather than a hole for every `id` kramdown can be talked into emitting.
  test "a heading keeps its id, normalized to a-z 0-9 and hyphens" do
    html = Maker::Markdown.render(<<~MD)
      # Desk Lamp

      ## Build steps

      ### Bill of Materials (v2)
    MD

    assert_match %r{<h1 id="desk-lamp">Desk Lamp</h1>}, html
    assert_match %r{<h2 id="build-steps">Build steps</h2>}, html
    assert_match %r{<h3 id="bill-of-materials-v2">}, html
  end

  test "a heading id kramdown built out of non-ascii is squeezed to the allowed alphabet" do
    # PROBED, NOT ASSUMED: kramdown answers `id="unicode-ü--symbols"` here — a character outside
    # [a-z0-9-] AND a double hyphen, both straight from its own auto_id generator.
    html = Maker::Markdown.render("## Unicode ü & Symbols!\n")

    assert_match %r{<h2 id="unicode-symbols">}, html
    assert_no_match(/ü"/, html)
  end

  test "an id on anything that is not a heading is dropped" do
    # Two ways to get one: kramdown's block IAL, and raw HTML. Both reach the fragment.
    html = Maker::Markdown.render("Some text\n{: #para-ial}\n\n<p id=\"raw\">raw</p>\n")

    assert_includes html, "Some text"
    assert_no_match(/id="para-ial"/, html)
    assert_no_match(/id="raw"/, html)
  end

  test "a raw-HTML heading's hand-written id is normalized rather than trusted" do
    html = Maker::Markdown.render(%(<h2 id="Clobber Me!">Raw</h2>\n))

    assert_match %r{<h2 id="clobber-me">Raw</h2>}, html
  end

  test "a heading whose id normalizes to nothing loses the attribute rather than carrying an empty one" do
    html = Maker::Markdown.render(%(<h2 id="一二三">Three</h2>\n))

    assert_match %r{<h2>Three</h2>}, html
  end
```

- [ ] **Step 2: fix the assertion allowing ids breaks.** `markdown_test.rb:16` reads `assert_match %r{<h1>Title</h1>}, html`. Change it to:

```ruby
    # `id="title"` since stage 4, S4-4 — kramdown always emitted it, ALLOWED_ATTRS used to strip it.
    assert_match %r{<h1 id="title">Title</h1>}, html
```

- [ ] **Step 3: run, expect FAIL.** `bin/rails test test/services/maker/markdown_test.rb` → the five new tests fail on the missing `id`, and the edited one fails too (the attribute is still stripped). Report the count.

- [ ] **Step 4: implement.** In `app/services/maker/markdown.rb`:

(a) `ALLOWED_ATTRS` gains `id`, with the reason beside it:

```ruby
    # `id` IS ALLOWED FOR HEADINGS AND FOR NOTHING ELSE, AND THE ALLOWLIST CANNOT SAY SO — Rails'
    # `sanitize` takes one flat attribute list with no per-tag arm, so `id` here would also permit
    # one on `<a>`, `<img>`, `<p>` and every other allowed element. `#keep_heading_anchors` below
    # is the half that makes this narrow: it runs BEFORE the sanitizer and strips every `id` off
    # anything that is not h1–h6. Adding the attribute here without that pass is the hole.
    ALLOWED_ATTRS = %w[href src alt title id].freeze

    # WHAT AN ANCHOR MAY CONTAIN. Not decoration: kramdown's own auto_id generator answers
    # `unicode-ü--symbols` for `## Unicode ü & Symbols!` (probed), a block IAL can hand any block
    # element any id at all, and RAW HTML passes an `id` through verbatim — so "kramdown already
    # sanitizes it" is false in all three directions. Anything outside this set collapses to a
    # single hyphen; an id that survives as empty loses the attribute rather than becoming `id=""`.
    ANCHOR_ALPHABET = /[^a-z0-9-]+/
    HEADINGS = %w[h1 h2 h3 h4 h5 h6].freeze
```

(b) rename the private `rewrite_relative_links` to `rewrite_fragment`, since it now does two things — three call sites in this file plus its own `def`:

- `:18` — `That is why \`rewrite_relative_links\` removes the EXECUTABLE` → `` `rewrite_fragment` ``
- `:36` — `see rewrite_relative_links` → `see rewrite_fragment`
- `:53` — `left for each caller of #rewrite_relative_links` → `#rewrite_fragment`
- `:46` — `rewritten = rewrite_relative_links(html) { … }` → `rewrite_fragment(html) { … }`
- `:62` — `def rewrite_relative_links(html)` → `def rewrite_fragment(html)`

(c) inside `rewrite_fragment`, directly after the `fragment.css("script, style, …").each(&:remove)` line and before the `a[href]` loop:

```ruby
        keep_heading_anchors(fragment)
```

(d) the new private method, beside `absolute_href?`:

```ruby
      # HEADING ANCHORS, AND THE STRIPPING THAT MAKES THEM SAFE (stage 4, S4-4; story 5.4). ONE
      # pass over the fragment the caller already parsed — never a second Nokogiri parse, which is
      # what would let the two passes disagree about what the document is.
      #
      # AN `id` ON ANYTHING BUT A HEADING IS REMOVED, not normalized: kramdown's block IAL
      # (`{: #x}`) and raw HTML both put ids on ordinary elements, none of them is an anchor anyone
      # linked to, and an attacker-chosen `id` on an allowed element is DOM clobbering
      # (`<img id="attributes">` shadows a property on the form it sits in). The heading case is the
      # only one with a reason to exist, so it is the only one kept.
      def keep_heading_anchors(fragment)
        fragment.css("[id]").each do |el|
          next el.remove_attribute("id") unless HEADINGS.include?(el.name)

          slug = el["id"].to_s.downcase.gsub(ANCHOR_ALPHABET, "-").gsub(/-+/, "-")
                   .delete_prefix("-").delete_suffix("-")
          slug.empty? ? el.remove_attribute("id") : el["id"] = slug
        end
      end
```

- [ ] **Step 5: run, expect PASS.** `bin/rails test test/services/maker/markdown_test.rb test/services/maker/readme_test.rb test/integration/web/public_project_test.rb test/integration/web/project_repo_card_test.rb` → 0 failures. (The last two render READMEs through this class; a heading that suddenly carries an id must not disturb their selectors.)

- [ ] **Step 6: mutation checks, two of them, because one assertion alone cannot carry this.**
  - (i) Delete the `keep_heading_anchors(fragment)` call. Run → **"an id on anything that is not a heading is dropped" FAILS** on `id="para-ial"`, and the raw-heading test fails on `id="Clobber Me!"`. Restore; PASS.
  - (ii) Restore the call and instead revert `ALLOWED_ATTRS` to `%w[href src alt title]`. Run → **"a heading keeps its id" FAILS** on `<h1 id="desk-lamp">`. Restore; PASS.
  Report all four outputs. The pair is the point: (i) alone would pass with the attribute disallowed (the pass would be doing nothing observable), and (ii) alone would pass with the pass deleted.

- [ ] **Step 7: commit.**

```bash
git add app/services/maker/markdown.rb test/services/maker/markdown_test.rb
git commit -m "A README's headings keep their anchors, and every other id is dropped before the sanitizer sees it"
```

---

### Task B: `Maker::TextSave` — the ONE text save

**Files:**
- Create: `app/services/maker/text_save.rb`
- Modify: `app/controllers/files_controller.rb` (`#update` only)
- Test: new `test/services/maker/text_save_test.rb`; run `test/integration/web/repo_edit_flow_test.rb` unchanged

- [ ] **Step 1: the failing test.** Create `test/services/maker/text_save_test.rb`:

```ruby
require "test_helper"
require "support/git_repo_fixture"

module Maker
  # THE ONE TEXT SAVE (stage 4, S4-4). FilesController#update (a file inside a working tree) and
  # Projects::ReadmesController#update (the project's README, anywhere) are the same operation seen
  # twice — stale-check, write through the port keeping the node, record a pending git edit — and a
  # second copy of it is where the 409 or the `replace:` quietly goes missing on one of the two.
  #
  # OWNS A SHARE LIBRARY: this writes real bytes through the port, so it pins share rather than
  # hitting the s3 stub bucket and the sync server's provisioning on the other two legs.
  class TextSaveTest < ActiveSupport::TestCase
    include GitRepoFixture

    setup do
      @library = use_fresh_share_library!
      @user = User.create!(email: "textsave-#{SecureRandom.hex(4)}@example.com",
                           password: "correct horse battery staple", confirmed_at: Time.current)
      @folder = Maker::LibraryFolder.ensure_path!(@user, [ "Docs" ])
    end

    def write!(name, body)
      Maker::Addons::LibraryOutput.write_bytes!(@user, parent_node_id: @folder.node_id, name:, bytes: body)
      Library::ScanJob.new.perform(user_id: @user.id)
      @user.nodes.present.find_by!(parent_node_id: @folder.node_id, name:)
    end

    def token_for(node) = FileLayer.current.stat(@user, node_id: node.node_id)&.content_token

    test "an existing file is rewritten IN PLACE, keeping its node_id, and the new token comes back" do
      node = write!("README.md", "# Old\n")
      before = node.node_id

      result = Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id,
                                    name: node.name, body: "# New\n", base_token: token_for(node))

      assert result.ok, result.error
      assert_equal before, result.node_id, "a replace must REUSE the node (§14a) — every attachment is keyed on it"
      assert_equal "# New\n", FileLayer.current.read(@user, node_id: before)
      assert_equal token_for(node), result.content_token
    end

    test "a stale base_token is a conflict and writes nothing" do
      node = write!("README.md", "# Old\n")

      result = Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id,
                                    name: node.name, body: "# New\n", base_token: "stale")

      refute result.ok
      assert_equal :conflict, result.status
      assert_equal "# Old\n", FileLayer.current.read(@user, node_id: node.node_id)
    end

    test "no node creates the file at the folder root" do
      result = Maker::TextSave.call(user: @user, node: nil, parent_node_id: @folder.node_id,
                                    name: "README.md", body: "# Fresh\n", base_token: nil)

      assert result.ok, result.error
      assert_equal "# Fresh\n", FileLayer.current.read(@user, node_id: result.node_id)
    end

    test "a create whose name is already taken is refused by the port, not silently clobbered" do
      write!("README.md", "# Old\n")

      assert_raises(FileLayer::UnsupportedOperation) do
        Maker::TextSave.call(user: @user, node: nil, parent_node_id: @folder.node_id,
                             name: "README.md", body: "# New\n", base_token: nil)
      end
    end

    test "a repo root records a pending edit; no repo root records none" do
      node = write!("README.md", "# Old\n")

      Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id, name: node.name,
                           body: "# A\n", base_token: token_for(node))
      assert_equal 0, Maker::RepoEdit.where(user: @user).count

      Maker::TextSave.call(user: @user, node:, parent_node_id: @folder.node_id, name: node.name,
                           body: "# B\n", base_token: token_for(node), repo_root_node_id: @folder.node_id)
      assert_equal [ node.node_id ], Maker::RepoEdit.where(user: @user).pluck(:node_id)
    end
  end
end
```

- [ ] **Step 2: run, expect NameError.** `bin/rails test test/services/maker/text_save_test.rb` → `uninitialized constant Maker::TextSave`.

- [ ] **Step 3: create the service** `app/services/maker/text_save.rb`:

```ruby
module Maker
  # SAVING TEXT INTO A LIBRARY FILE, ONCE (stage 4, S4-4). Two doors perform this verb —
  # FilesController#update (a file inside a working tree, §14d's git surface) and
  # Projects::ReadmesController#update (the project's README, on any backend, D3's exception) — and
  # a verb more than one controller performs gets a named service rather than being re-inlined
  # (§14d). What must not drift between them is exactly what lives here:
  #
  #   * THE STALE CHECK. The caller edited SOME version; if the port's content token has moved
  #     since, the save would silently discard whatever moved it. 409, never a write.
  #   * `replace: true`, WHICH REUSES THE NODE. A delete-then-create passes any bytes-oriented test
  #     while orphaning every attachment, BOM line and tag on that node — nothing errors and
  #     nothing logs, which is the whole signature (§14a, git-editing.md's opening rule).
  #   * THE PENDING GIT EDIT, gated on `local_worktree?`. On a backend that does not hold the
  #     working tree the bytes still land; there is just no commit box on this box to review them
  #     in.
  #
  # WHAT IS DELIBERATELY NOT HERE: the size cap and the FetchError → 503 mapping. Both are the
  # DOOR's, because each door words them differently and §14a maps FetchError once, at the
  # controller. This service raises FileLayer errors to its caller unchanged — including the
  # clobber refusal (UnsupportedOperation) a create hits when the name is already taken, which is
  # the honest answer for a file that appeared while the maker was typing.
  class TextSave
    Result = Data.define(:ok, :status, :error, :content_token, :node_id)

    STALE = "This file changed since you opened it. Reload to see the current version.".freeze
    APPEARED = "A file already exists here. Reload to see it.".freeze

    # node: the live Node being rewritten, or nil to CREATE `name` under `parent_node_id`.
    def self.call(user:, node:, parent_node_id:, name:, body:, base_token:, repo_root_node_id: nil)
      if node
        info = FileLayer.current.stat(user, node_id: node.node_id)
        return refusal(STALE) if info&.content_token.to_s != base_token.to_s
      elsif base_token.present?
        # A CREATE THAT CARRIES A TOKEN IS A CREATE AGAINST A FILE THAT NOW EXISTS: the door
        # rendered "there is no README here" and one appeared. Refused before the port so the
        # message names the situation rather than the adapter's clobber wording.
        return refusal(APPEARED)
      end

      node_id = Maker::Addons::LibraryOutput.write_bytes!(
        user, parent_node_id: node ? node.parent_node_id : parent_node_id,
        name: node ? node.name : name, bytes: body.to_s.b, replace: node.present?
      )
      Maker::RepoEdit.record!(user:, repo_root_node_id:, node_id:) if
        repo_root_node_id.present? && FileLayer.current.capabilities.local_worktree?

      Result.new(ok: true, status: :ok, error: nil, node_id:,
                 content_token: FileLayer.current.stat(user, node_id:)&.content_token)
    end

    def self.refusal(message) = Result.new(ok: false, status: :conflict, error: message,
                                           content_token: nil, node_id: nil)
    private_class_method :refusal
  end
end
```

- [ ] **Step 4: run, expect PASS.** `bin/rails test test/services/maker/text_save_test.rb` → 5 runs, 0 failures.

- [ ] **Step 5: `FilesController#update` calls it.** Replace the body between the `editable?` guard and the `render json:` line (currently `app/controllers/files_controller.rb:541-552`) with:

```ruby
    # THE SHARED SAVE (stage 4, S4-4). The stale check, the `replace: true` write that REUSES the
    # node, and the pending git edit all moved to Maker::TextSave when the project page's README
    # editor became a second door onto the same verb. THIS door keeps its own two rules: the size
    # cap above (the SERVER is what enforces it — git-editing.md) and the FetchError → 503 below.
    result = Maker::TextSave.call(user: current_user, node:, parent_node_id: node.parent_node_id,
                                  name: node.name, body: params[:content], base_token: params[:base_token],
                                  repo_root_node_id: root.node_id)
    return render_save_error(result.status, result.error) unless result.ok

    render json: { ok: true, content_token: result.content_token }
```

Leave the `rescue FileLayer::FetchError => e` arm exactly as it is.

- [ ] **Step 6: run the file-page suites, expect PASS with NO edits to them.** `bin/rails test test/integration/web/repo_edit_flow_test.rb test/integration/web/file_page_test.rb test/integration/web/files_git_marker_test.rb test/architecture_invariants_test.rb` → 0 failures. **If any of them needed changing, the extraction changed behaviour — stop and find out why**; the point of the refactor is that they do not.

- [ ] **Step 7: mutation check.** In `text_save.rb` change `replace: node.present?` to `replace: false`. Run `bin/rails test test/services/maker/text_save_test.rb` → **"an existing file is rewritten IN PLACE" FAILS** with `FileLayer::UnsupportedOperation` (the clobber refusal), which is the guard proving the port really is being asked to replace rather than create. Then change it to `replace: true` unconditionally and run again → **"a create whose name is already taken is refused" FAILS**, because a replace of a file the caller thinks is absent succeeds. Restore; PASS. Report all three outputs.

- [ ] **Step 8: commit.**

```bash
git add app/services/maker/text_save.rb app/controllers/files_controller.rb test/services/maker/text_save_test.rb
git commit -m "One text save for two doors: the stale check, the node-reusing write and the pending edit in one place"
```

---

### Task G: the git-editing exception, argued (runs in parallel with A and B)

**Files:**
- Modify: `docs/invariants/git-editing.md`

- [ ] **Step 1: add the exception directly after the file's opening rule** ("Bytes the catalog tracks go through the port; bytes git owns never do", which ends at the `Routing the file write around the port` bullet, `:37-45`). It goes there rather than at the end because it is an exception to *that* rule and a reader who has just read it must meet the exception in the same breath:

```markdown
## The Markdown exception: a project's README is editable without a repository

**Stage 4, S4-4 (spec §2 D3).** `FilesController#update` refuses a file that is not inside a
working tree, and every rule above is why. **One door is exempt**: `PATCH /projects/:id/readme`
(`Projects::ReadmesController#update`) writes the project folder's own README on **any** backend,
repository or not.

**Why this one and not the others.** The refusal exists because a save on share or s3 overwrites
with no undo, and git is the undo. For documentation the alternative is not "edit it somewhere
safer" — it is **no README at all**: on the measured share deployment, 0 of 9 real projects had one
the app would show (spec §1). A rule that protects a file nobody ever writes has protected nothing.
So the trade is **named on the editor** — "This library keeps no history for this file; saving
replaces it." on share and s3, nothing on chunk_remote, decided by `capabilities.versioned?` — and
the maker chooses with the cost in front of them.

**What still holds, unchanged, and what breaks if you undo any of it.**

- **The bytes go through the port**, `Maker::TextSave` → `Maker::Addons::LibraryOutput.write_bytes!`
  → `FileLayer#write` / the two-phase upload. Never `File.write`, never a delete-then-create: both
  orphan every attachment, BOM line and tag on the node, silently (§14a).
- **`replace: true`, so the node survives.** A README is attachable, taggable and BOM-linkable like
  any other file.
- **The `base_token` 409.** The editor edited some version; if the port's content token moved
  under it, the save is refused rather than discarding whatever moved it.
- **A `.lock` is still refused and never deleted**, and a detached HEAD or a half-finished
  operation still refuses — this door does not touch `Maker::Git::LocalRepo` at all, so it inherits
  those refusals by not having a git path to skip.
- **Restore is still git-only** and still writes a pending edit rather than committing. There is no
  "undo" on this door, which is exactly what the note on the editor says.
- **A pending `Maker::RepoEdit` is still recorded when the folder IS a working tree**, so a README
  saved in a repository shows up in the commit box like any other edit.
- **The 200,000-byte cap is still the SERVER's**, read from `FilesController::EDITABLE_MAX_BYTES`
  rather than copied.

**The exception is confined STRUCTURALLY, not by a name check.** The door takes **no node id from
the client**: it resolves the file through `Maker::Readme.row_in(listing.loose)` — the same call
both project-page cards render from — so the only file it can ever write is one of the six
`Maker::Readme::NAMES` at the project folder's root. There is no parameter to point somewhere else
and no predicate to loosen. D3's fuller wording ("Markdown is editable anywhere", story 2.13) is
**not** implemented: widening `FilesController#update` to any `.md` outside a repository is a second
door with its own surfaces — the file page's editor, its own no-history note, its stale thumbnail —
and **needs its own spec and its own slice**. Do not widen this one to get there.
```

- [ ] **Step 2: run the docs guard.** `bin/rails test test/docs_hygiene_test.rb` → PASS (the §14l stub in CLAUDE.md still points at this file; nothing about the stub changes).

- [ ] **Step 3: commit.**

```bash
git add docs/invariants/git-editing.md
git commit -m "The Markdown exception to the git-editing rule, argued where the rule it excepts is stated"
```

---

### Task C: the README editor

Starts after B has committed.

**Files:**
- Modify: `config/routes.rb`, `app/controllers/projects_controller.rb` (`#show`), `app/services/maker/readme.rb`, `app/views/projects/_readme_card.html.erb`, `_repo_card.html.erb`, `_file_tree_section.html.erb`, `_attachments.html.erb`, `app/assets/stylesheets/pages/projects.css`
- Create: `app/controllers/projects/readmes_controller.rb`, `app/javascript/controllers/readme_controller.js`, `app/views/projects/_readme_editor.html.erb`, `app/views/shared/_no_history_note.html.erb`
- Test: new `test/integration/web/readme_edit_test.rb`, `test/services/maker/readme_test.rb`

- [ ] **Step 1: the failing tests.** Create `test/integration/web/readme_edit_test.rb`:

```ruby
require "test_helper"
require "support/git_repo_fixture"

module Web
  # STAGE 4, S4-4 (story 5.3; spec §2 D3): the README editor on the project page's README card, for
  # ANY project — a plain folder as much as a working tree.
  #
  # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY FIXTURE RUNS, for the reason
  # project_repo_card_test.rb records at its own setup: these tests write real bytes through the
  # port, and on the ambient s3 and chunk_remote legs the folder mkdir hits the stub bucket and the
  # sync server's provisioning. Pinning share is what makes the three legs report identical counts.
  class ReadmeEditTest < ActionDispatch::IntegrationTest
    include GitRepoFixture

    setup { @library = use_fresh_share_library! }

    PASSWORD = "correct horse battery staple".freeze

    def sign_in(email = "readme@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    def project_with_folder!(user, name: "Desk Lamp", readme: nil)
      project = user.maker_projects.create!(name:)
      project.ensure_library_folder!(user)
      File.write(File.join(library_root, "Projects", project.slug, "README.md"), readme) if readme
      Library::ScanJob.new.perform(user_id: user.id)
      project
    end

    def readme_node(user, project)
      folder = user.nodes.present.find_by!(node_id: project.reload.folder_node_id)
      user.nodes.present.find_by(parent_node_id: folder.node_id, name: "README.md")
    end

    def token_for(user, node) = FileLayer.current.stat(user, node_id: node.node_id)&.content_token

    # --- the card ------------------------------------------------------------------------------

    test "a folder with a README offers an Edit control carrying the blob url and the current token" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Lamp\n\nWalnut.\n")
      node = readme_node(user, project)

      get project_path(project)

      assert_response :success
      assert_select ".readme-card .readme-editor[data-controller=readme]"
      assert_select ".readme-editor[data-readme-url-value=?]", blob_file_path(node.node_id)
      assert_select ".readme-editor summary", text: "Edit README"
      assert_select ".readme-editor input[name=base_token][value=?]", token_for(user, node)
      assert_select ".readme-editor textarea[name=content][disabled=disabled]"
    end

    test "a folder with no README offers Write a README, pre-filled with the template and no token" do
      user = sign_in
      project = project_with_folder!(user)

      get project_path(project)

      assert_select ".readme-editor summary", text: "Write a README"
      assert_select ".readme-editor[data-readme-url-value=?]", ""
      assert_select ".readme-editor textarea[name=content]", /\A# Desk Lamp/
      assert_select ".readme-editor textarea[name=content]", /## Build log/
      assert_select ".readme-editor input[name=base_token]", 0
    end

    test "a project with no library folder offers no editor at all" do
      user = sign_in
      project = user.maker_projects.create!(name: "Folderless")
      project.update_column(:folder_node_id, nil)

      get project_path(project)

      assert_select ".readme-editor", 0
    end

    # --- the save ------------------------------------------------------------------------------

    test "saving an existing README rewrites it in place, keeps the node, and the card shows it" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Old\n")
      node = readme_node(user, project)

      patch project_readme_path(project),
            params: { content: "# Lamp\n\n## Build steps\n", base_token: token_for(user, node) }

      assert_redirected_to project_path(project)
      assert_equal "README saved.", flash[:notice]
      assert_equal node.node_id, readme_node(user, project).node_id, "a replace must reuse the node (§14a)"
      assert_equal "# Lamp\n\n## Build steps\n", FileLayer.current.read(user, node_id: node.node_id)

      follow_redirect!
      assert_select ".readme-card .markdown h2[id=build-steps]", text: "Build steps"
    end

    test "saving with no README creates README.md at the folder root" do
      user = sign_in
      project = project_with_folder!(user)

      patch project_readme_path(project), params: { content: "# Fresh\n" }

      assert_redirected_to project_path(project)
      node = readme_node(user, project)
      assert node, "README.md should exist at the folder root"
      assert_equal "# Fresh\n", FileLayer.current.read(user, node_id: node.node_id)
    end

    test "a stale token is refused and the bytes on disk are untouched" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Old\n")
      node = readme_node(user, project)

      patch project_readme_path(project), params: { content: "# New\n", base_token: "stale" }

      assert_redirected_to project_path(project)
      assert_match(/changed since you opened it/, flash[:alert])
      assert_equal "# Old\n", FileLayer.current.read(user, node_id: node.node_id)
    end

    test "a blank body is refused rather than emptying the README" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Old\n")
      node = readme_node(user, project)

      patch project_readme_path(project), params: { content: "  ", base_token: token_for(user, node) }

      assert_match(/needs some text/, flash[:alert])
      assert_equal "# Old\n", FileLayer.current.read(user, node_id: node.node_id)
    end

    # THE DOOR TAKES NO NODE ID, WHICH IS WHAT CONFINES D3'S EXCEPTION TO DOCUMENTATION
    # (git-editing.md). Extra params naming another file must change nothing about which file is
    # written — there is no parameter to point it somewhere else.
    test "the door writes the README and nothing else, whatever extra params are posted" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Old\n")
      folder = user.nodes.present.find_by!(node_id: project.reload.folder_node_id)
      File.write(File.join(library_root, "Projects", project.slug, "secrets.env"), "KEY=1\n")
      Library::ScanJob.new.perform(user_id: user.id)
      victim = user.nodes.present.find_by!(parent_node_id: folder.node_id, name: "secrets.env")

      patch project_readme_path(project),
            params: { content: "# New\n", base_token: token_for(user, readme_node(user, project)),
                      node_id: victim.node_id, name: "secrets.env" }

      assert_equal "KEY=1\n", FileLayer.current.read(user, node_id: victim.node_id)
      assert_equal "# New\n", FileLayer.current.read(user, node_id: readme_node(user, project).node_id)
    end

    test "another maker's project is a 404" do
      owner = sign_in("owner@example.com")
      project = project_with_folder!(owner)
      sign_in("intruder@example.com")

      patch project_readme_path(project), params: { content: "# Mine now\n" }

      assert_response :not_found
    end

    # --- the trade is named --------------------------------------------------------------------

    test "share says it keeps no history; a versioned backend says nothing" do
      user = sign_in
      project = project_with_folder!(user, readme: "# Lamp\n")

      get project_path(project)

      if FileLayer.current.capabilities.versioned?
        assert_select ".readme-editor .no-history-note", 0
      else
        assert_select ".readme-editor .no-history-note", text: /keeps no history for this file/
      end
    end

    # --- a root repository gets the same editor, plus a pending edit ----------------------------

    test "a root working tree gets the editor inside its repo card and the save records a pending edit" do
      user = sign_in
      project = user.maker_projects.create!(name: "Firmware")
      project.ensure_library_folder!(user)
      dir = File.join(library_root, "Projects", project.slug)
      repo = Rugged::Repository.init_at(dir)
      File.write(File.join(dir, "README.md"), "# Firmware\n")
      index = repo.index
      index.add(path: "README.md", oid: Rugged::Blob.from_workdir(repo, "README.md"), mode: 0o100644)
      index.write
      who = { name: "Seed", email: "seed@example.com", time: Time.at(1_700_000_000) }
      Rugged::Commit.create(repo, tree: index.write_tree(repo), message: "First", parents: [],
                            update_ref: "HEAD", author: who, committer: who)
      Library::ScanJob.new.perform(user_id: user.id)
      node = readme_node(user, project)

      get project_path(project)
      assert_select ".repo-card .readme-editor[data-controller=readme]"

      patch project_readme_path(project),
            params: { content: "# Firmware v2\n", base_token: token_for(user, node) }

      assert_equal [ node.node_id ], Maker::RepoEdit.where(user:).pluck(:node_id)
      assert_equal project.reload.folder_node_id,
                   Maker::RepoEdit.find_by(user:, node_id: node.node_id).repo_root_node_id
    end
  end
end
```

- [ ] **Step 2: run, expect FAIL.** `bin/rails test test/integration/web/readme_edit_test.rb` → every test fails; the save ones on `undefined local variable or method 'project_readme_path'`.

- [ ] **Step 3: the template and the route.**

(a) In `app/services/maker/readme.rb`, after `READ_LIMIT`:

```ruby
    # WHAT "WRITE A README" STARTS FROM (stage 4, S4-4). Short on purpose: a template a maker has to
    # delete half of is worse than a blank page. The two headings are the two things the project
    # page already has and the README cannot see — the folder's files and the build log — so the
    # template's job is to say "these are the sections worth writing", not to write them.
    #
    # `NAMES.first` IS THE NAME A CREATE USES, read from the preference order rather than spelled
    # again: the list is the preference order, so the first entry is what this app would rather find.
    def self.template_for(project)
      <<~MD
        # #{project.name}

        #{project.description.presence || "One line about what this is."}

        ## Files

        ## Build log
      MD
    end
```

(b) In `config/routes.rb`, inside `resources :projects do`, directly after the `resource :scan, only: :create, module: :projects` line:

```ruby
    # THE README, AS A DOOR RATHER THAN A FILE (stage 4, S4-4; spec §2 D3). SINGULAR: a project has
    # one README and the door takes NO node id — it resolves the row from the project's own listing
    # (Maker::Readme.row_in), which is what confines the git-editing exception to documentation
    # (docs/invariants/git-editing.md). `update` only: creating README.md is still an update to
    # "the project's README", and deleting one is the Files page's delete like any other file.
    resource :readme, only: :update, module: :projects
```

- [ ] **Step 4: the controller.** Create `app/controllers/projects/readmes_controller.rb`:

```ruby
module Projects
  # PATCH /projects/:project_id/readme — the project folder's own README, written from the project
  # page (stage 4, S4-4; spec §2 D3, story 5.3). Session-authed web layer (§14d).
  #
  # THE ONE EXCEPTION TO "NO REPOSITORY, NO EDITING", AND IT IS CONFINED BY SHAPE RATHER THAN BY A
  # CHECK: this action takes no node id, no name and no parent — it asks the project's own listing
  # which row is the README (Maker::Readme.row_in owns that preference order) and writes that, or
  # creates NAMES.first when there is none. There is no parameter that could point it at another
  # file, which is why docs/invariants/git-editing.md can describe the exception as one door rather
  # than as a predicate someone can loosen.
  #
  # ALWAYS A REDIRECT, NEVER A RE-RENDER OR JSON — Settings::HandlesController's argument, and one
  # more: the whole point of this door (story 5.3) is to SEE the README rendered on your own page,
  # so landing back on that page with the card redrawn is the feature, not a consolation.
  class ReadmesController < ApplicationController
    def update
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      listing = Maker::ProjectFolderListing.new(current_user, project)
      body = params[:content].to_s
      return refuse(project, "This project has no folder in the library yet.") unless listing.available?
      # A BLANK BODY IS REFUSED RATHER THAN WRITTEN, and it is the SERVER half of the editor's
      # `disabled` textarea: without JavaScript, or with the bundle failing to load, the buffer is
      # empty and a Save would otherwise blank a README that took an hour to write. Emptying a file
      # to zero bytes is not a thing anyone asks for; deleting it is, on the Files page.
      return refuse(project, "A README needs some text. To remove it, delete the file from the Files page.") if body.strip.empty?
      return refuse(project, "This README is too large to edit here.") if
        body.bytesize > FilesController::EDITABLE_MAX_BYTES

      row = Maker::Readme.row_in(listing.loose)
      return refuse(project, "This README is too large to edit here.") if
        row && row.node.size.to_i > FilesController::EDITABLE_MAX_BYTES

      result = Maker::TextSave.call(
        user: current_user, node: row&.node, parent_node_id: listing.folder_id,
        name: Maker::Readme::NAMES.first, body:, base_token: params[:base_token],
        # THE PENDING EDIT ONLY WHEN THE FOLDER ITSELF IS THE WORKING TREE. A repository NESTED in
        # the folder has its own README and its own commit box; this door never touches it.
        repo_root_node_id: (listing.folder_id if listing.root_repo?)
      )
      return refuse(project, result.error) unless result.ok

      redirect_to project_path(project), notice: "README saved."
    rescue FileLayer::UnsupportedOperation
      # THE CLOBBER REFUSAL (§14a): a README appeared between the render and the Save, so the
      # create found the name taken. Refused, never replaced — the maker has not seen what is there.
      refuse(project, "A README appeared while you were writing. Reload the page to see it.")
    rescue FileLayer::FetchError => e
      refuse(project, e.message)
    end

    private

    def refuse(project, message)
      redirect_to project_path(project), alert: message
    end
  end
end
```

- [ ] **Step 5: `ProjectsController#show` resolves the row once.** Directly after the `@root_card = nil` / `@readme = nil` block ends (`app/controllers/projects_controller.rb:193`, the `end` closing `if @listing.available?`), insert:

```ruby
    # THE README THE EDITOR EDITS (stage 4, S4-4), resolved ONCE from the same rows both cards
    # render — Maker::Readme.row_in is the one definition of the preference order, so the card that
    # shows a README and the door that saves it cannot disagree about which file that is. In memory
    # over @listing: no query, no port call.
    #
    # `@readme_editable` IS TRUE WITH NO README AT ALL — that is the "Write a README" case, which is
    # the whole of story 5.3 for the 9 of 9 measured projects that have none. The size cap is read
    # from FilesController's constant rather than spelled again (git-editing.md: the SERVER is what
    # enforces it, and two copies of a number is how they drift).
    @readme_row = @listing.available? ? Maker::Readme.row_in(@listing.loose) : nil
    @readme_editable = @listing.available? &&
                       (@readme_row.nil? || @readme_row.node.size.to_i <= FilesController::EDITABLE_MAX_BYTES)
```

- [ ] **Step 6: the two shared partials.**

`app/views/shared/_no_history_note.html.erb`:

```erb
<%#
  THE TRADE, NAMED WHERE IT IS TAKEN (stage 4, S4-4; spec §2 D3). Saving over a file on a share or
  an s3 bucket destroys the old bytes — that is exactly why docs/invariants/git-editing.md refuses
  editing outside a repository, and the one place this app takes that trade anyway is a README,
  because the alternative measured on the live deployment was no README at all. So the sentence
  goes on the editor rather than in a document nobody reading it will open.

  ONE PARTIAL SO THE SENTENCE HAS ONE DEFINITION. Asked of `capabilities.versioned?`, never of an
  adapter class (§14a / git-editing.md): chunk_remote keeps every version regardless, so it says
  nothing at all rather than a hedge.
%>
<% unless capabilities.versioned? %>
  <p class="muted no-history-note">This library keeps no history for this file; saving replaces it.</p>
<% end %>
```

`app/views/projects/_readme_editor.html.erb`:

```erb
<%#
  THE README EDITOR (stage 4, S4-4; story 5.3). Mounted inside BOTH cards' `.readme` region —
  projects/_readme_card for a plain folder, projects/_repo_card for a folder that IS a working
  tree — so a maker writes documentation the same way whichever shape their project has.

  Locals: project, row (the README's Maker::ProjectFolderListing::Row, or nil when there is none).

  CLOSED, AND LAZY (the modelviewer `lazy` argument): readme_controller.js fetches the README's
  bytes on the first toggle-open and not before, so a project page nobody edits pays no port read
  at all and page_query_budget_test.rb is untouched by this feature.

  THE TEXTAREA AND THE BUTTON START DISABLED and are enabled by the controller once the buffer
  holds the real bytes. Without that, a failed bundle load plus a click on Save posts an EMPTY
  buffer over a README that took an hour to write. The server refuses a blank body as well
  (Projects::ReadmesController) — two halves, because a rule that lives only in JavaScript is one
  curl walks past, which is the same argument FilesController::EDITABLE_MAX_BYTES already makes.

  PLAIN TAG HELPERS, NOT `f.text_area`. `form_with url:` with no model has a blank object_name, and
  a field built through the builder would be named "content" anyway — but `fields_for` on a blank
  object_name emits the literal bracket key Rack cannot parse (§14d, shipped twice). Flat names,
  read as params[:content] / params[:base_token], exactly as FilesController#update reads them.
%>
<details class="composer readme-editor" data-controller="readme" data-action="toggle->readme#reveal"
         data-readme-url-value="<%= row ? blob_file_path(row.node_id) : "" %>">
  <summary class="btn small"><%= row ? "Edit README" : "Write a README" %></summary>

  <%= render "shared/no_history_note" %>

  <%= form_with url: project_readme_path(project), method: :patch, class: "readme-form",
                data: { action: "submit->readme#sync" } do %>
    <% if row %>
      <%= hidden_field_tag :base_token, FileLayer.current.stat(current_user, node_id: row.node_id)&.content_token %>
    <% end %>
    <div class="readme-mount" data-readme-target="mount"></div>
    <%= text_area_tag :content, (row ? "" : Maker::Readme.template_for(project)),
                      rows: 16, disabled: true, spellcheck: true,
                      class: "readme-source", data: { readme_target: "input" } %>
    <div class="readme-bar">
      <%= submit_tag "Save README", class: "btn small primary", disabled: row.present?,
                     data: { readme_target: "submit" } %>
      <span class="muted readme-status" data-readme-target="status"></span>
    </div>
  <% end %>
</details>
```

> **`disabled: row.present?` on the submit is not a typo.** With no README the textarea already
> holds the template, so there is nothing to fetch and Save is live immediately (and works with no
> JavaScript at all). With a README, Save waits for the fetch. The textarea is disabled in both
> cases because CodeMirror replaces it either way; `readme_controller#reveal` enables it.

- [ ] **Step 7: the two cards mount it.**

`app/views/projects/_readme_card.html.erb` — replace the whole file (its header sentence about never rendering empty is now false, and the "same task sweeps every file that documents it" rule applies):

```erb
<%#
  THE README CARD FOR A PLAIN FOLDER (stage 4, S4-1): the project's root README rendered on the
  maker's own page. Until S4-1 a README was rendered only inside a repository's card
  (projects/_repo_card) and on the PUBLIC page — a maker with a plain folder saw their own
  documentation only by publishing it. Same reader (Maker::Readme), same `.markdown` rendering,
  same `.readme` details; no git facts, because there is no git. Shares `.repo-card`'s frame on
  purpose — one card look for "what this folder says about itself".

  SINCE STAGE 4, S4-4 IT ALSO RENDERS WITH NO README AT ALL. That is not an empty card: it is the
  "Write a README" door, and it is the case 9 of the 9 measured real projects were in. `readme` is
  nil then, and this partial renders the editor alone.

  Locals: readme (a Maker::Readme, or nil when the folder holds none), editable (S4-4: may this
  maker write it here?), readme_row (the README's row, or nil), project.
%>
<div class="repo-card readme-card">
  <% if readme&.html.present? %>
    <details class="readme" open>
      <summary>README</summary>
      <div class="markdown"><%= readme.html %></div>
      <% if readme.note %>
        <p class="muted readme-note"><%= readme.note %></p>
      <% end %>
      <% if editable %><%= render "projects/readme_editor", project:, row: readme_row %><% end %>
    </details>
  <% else %>
    <% if readme&.note %>
      <p class="muted readme-note"><%= readme.note %></p>
    <% end %>
    <% if editable %><%= render "projects/readme_editor", project:, row: readme_row %><% end %>
  <% end %>
</div>
```

`app/views/projects/_repo_card.html.erb` — add the same two lines. After the `<div class="markdown">…</div>` / note block, the tail becomes:

```erb
  <% if card.readme_html.present? %>
    <details class="readme" open>
      <summary>README</summary>
      <div class="markdown"><%= card.readme_html %></div>
      <% if card.readme_note %>
        <p class="muted readme-note"><%= card.readme_note %></p>
      <% end %>
      <% if local_assigns[:editable] %>
        <%= render "projects/readme_editor", project: local_assigns[:project], row: local_assigns[:readme_row] %>
      <% end %>
    </details>
  <% else %>
    <% if card.readme_note %>
      <p class="muted readme-note"><%= card.readme_note %></p>
    <% end %>
    <% if local_assigns[:editable] %>
      <%= render "projects/readme_editor", project: local_assigns[:project], row: local_assigns[:readme_row] %>
    <% end %>
  <% end %>
```

and add to its header comment:

```erb
  STAGE 4, S4-4: the ROOT card also carries the README editor. `local_assigns[:editable]` DEFAULTS
  TO FALSE — projects/_file_tree_section renders this partial for every NESTED repository too, and
  a nested repo's README is not the project's README (the door writes only the project folder's
  own). Defaulting to the safe answer is deliberate: an unwritten third caller gets a card with no
  editor rather than an editor pointed at the wrong file (§14a makes the same argument for
  finalize_upload's broadcast default).
```

`app/views/projects/_file_tree_section.html.erb:52` — make the nested call say so out loud rather than relying on the default:

```erb
        <%= render "projects/repo_card", card:, editable: false %>
```

- [ ] **Step 8: the card slot in `_attachments.html.erb`.** Re-anchor on the text `<%# THE ROOT'S CARD (stage 4, S4-1)` and replace that comment block and its `if`/`elsif` with:

```erb
  <%# THE ROOT'S CARD (stage 4, S4-1), above the groups, for every project that has one: the
      repository card when the folder itself is a working tree (README, latest commit, tag), the
      README alone otherwise. Outside the empty check below on purpose — a README is content.
      STAGE 4, S4-4: the card renders even with NO README, because it now carries the "Write a
      README" door (@readme_editable is true whenever the folder is available). %>
  <% if @root_card %>
    <%= render "projects/repo_card", card: @root_card, project: @project,
               readme_row: @readme_row, editable: @readme_editable %>
  <% elsif @readme || @readme_editable %>
    <%= render "projects/readme_card", readme: @readme, editable: @readme_editable,
               readme_row: @readme_row, project: @project %>
  <% end %>
```

- [ ] **Step 9: the Stimulus controller.** Create `app/javascript/controllers/readme_controller.js`:

```js
import { Controller } from "@hotwired/stimulus"

// The README editor on the project page (stage 4, S4-4; story 5.3). Upgrades a plain <textarea> to
// CodeMirror and copies the buffer back into it on submit — the form is an ordinary PATCH that
// redirects, so there is no JSON, no error surface and no token roll-forward here. That is the
// difference from editor_controller.js, which must stay on the file page and therefore fetches.
//
// LAZY, ON THE <details> TOGGLE. The bytes are fetched the first time the editor is opened and
// never on a page nobody edits, which is what keeps the project page's port reads (and its query
// budget) exactly where S4-1 left them.
//
// THE FIELDS ARE ENABLED ONLY ONCE THE BUFFER HOLDS THE REAL BYTES. Rendered disabled by the
// partial: a bundle that fails to load, or a fetch that 503s on an unmounted NAS, must not leave a
// Save button that posts an empty document over the file. The server refuses a blank body too —
// this is the courteous half, the same split FilesController::EDITABLE_MAX_BYTES already has.
const MAX_BYTES = 200_000

export default class extends Controller {
  static targets = ["input", "mount", "status", "submit"]
  static values = { url: String }

  connect() {
    this.loaded = false
    this.disconnected = false
    this.abort = new AbortController()
    // An editor left open by a Turbo restore must still load its bytes.
    if (this.element.open) this.reveal()
  }

  async reveal() {
    if (!this.element.open || this.loaded) return
    this.loaded = true

    // A DECLARED-BUT-EMPTY VALUE IS THE "no README yet" CASE, and `hasUrlValue` is true for it —
    // Stimulus reports a declared String value as present however empty. The template is already
    // in the textarea then, so there is nothing to fetch.
    if (this.urlValue) {
      try {
        const res = await fetch(this.urlValue, { credentials: "same-origin", signal: this.abort.signal })
        if (!res.ok) throw new Error(`fetch failed (${res.status})`)
        const text = await res.text()
        if (this.disconnected) return
        if (text.length > MAX_BYTES) {
          this.statusTarget.textContent = "This README is too large to edit here."
          return
        }
        this.inputTarget.value = text
      } catch (e) {
        if (this.disconnected) return
        this.statusTarget.textContent = `Could not load the README: ${e.message}`
        return
      }
    }

    this.inputTarget.disabled = false
    if (this.hasSubmitTarget) this.submitTarget.disabled = false
    await this.mountEditor()
  }

  async mountEditor() {
    let cm, languages, theme
    try {
      ;[cm, languages, theme] = await Promise.all([
        import("codemirror"),
        import("lib/codemirror_languages"),
        import("lib/codemirror_theme")
      ])
    } catch (e) {
      // The plain textarea is already editable and already holds the bytes; that IS the degraded
      // state, and it is a working one. Same posture codeview/editor take with their <pre>.
      console.warn("[readme] keeping the plain textarea:", e)
      return
    }
    if (this.disconnected) return

    // `languageFor("md")` is already `cm.markdown()` — the bundle exports @codemirror/lang-markdown
    // (vendor/javascript/codemirror-entry.js). NO NEW PIN AND NO REBUILD: CodeMirror is ONE bundle
    // and exactly one importmap pin (§14d).
    const extensions = [cm.basicSetup, ...theme.themeExtensions(cm)]
    const language = languages.languageFor("md", cm)
    if (language) extensions.push(language)

    this.view = new cm.EditorView({
      state: cm.EditorState.create({ doc: this.inputTarget.value, extensions }),
      parent: this.mountTarget
    })
    this.inputTarget.hidden = true
  }

  // THE BUFFER GOES BACK INTO THE FIELD THE FORM ACTUALLY POSTS. Without this the form submits
  // whatever the textarea held when CodeMirror mounted — every edit silently discarded, with a
  // successful save and a redirect to prove it worked.
  sync() {
    if (this.view) this.inputTarget.value = this.view.state.doc.toString()
  }

  disconnect() {
    this.disconnected = true
    this.abort?.abort()
    this.view?.destroy()
    this.view = null
  }
}
```

- [ ] **Step 10: the CSS.** Append inside `pages/projects.css`'s `@layer pages { … }` block, after the `.panel--quiet` block:

```css
  /* --- The README editor (stage 4, S4-4): the composer inside a README card. `.composer` itself
     is a component (components.css) and is only QUALIFIED here, never redeclared — design-system
     rule 3. The mount and the textarea are two states of one control: CodeMirror renders into the
     first and hides the second, and with no JS the second is what the maker types into. --- */
  .readme-editor { margin-top: 10px; }
  .readme-editor .readme-form { display: flex; flex-direction: column; gap: 8px; }
  .readme-editor .readme-source { width: 100%; font: 12px/1.5 var(--font-mono); resize: vertical; }
  .readme-editor .readme-mount .cm-editor { max-height: 60vh; }
  .readme-editor .readme-bar { display: flex; align-items: center; gap: 10px; }
  .readme-editor .readme-status { font-size: 12px; }
  .readme-editor .no-history-note { margin: 0 0 8px; font-size: 12px; }
```

- [ ] **Step 11: a `Maker::Readme` test for the template.** Append to `test/services/maker/readme_test.rb`:

```ruby
  test "the template names the project and uses its description when there is one" do
    user = User.create!(email: "tpl-#{SecureRandom.hex(4)}@example.com",
                        password: "correct horse battery staple", confirmed_at: Time.current)
    plain = user.maker_projects.create!(name: "Desk Lamp")
    described = user.maker_projects.create!(name: "Sign", description: "A backlit sign.")

    assert_match(/\A# Desk Lamp\n\nOne line about what this is\./, Maker::Readme.template_for(plain))
    assert_match(/\A# Sign\n\nA backlit sign\./, Maker::Readme.template_for(described))
    assert_match(/## Files/, Maker::Readme.template_for(plain))
    assert_match(/## Build log/, Maker::Readme.template_for(plain))
  end
```

- [ ] **Step 12: run, expect PASS.** `bin/rails test test/integration/web/readme_edit_test.rb test/services/maker/readme_test.rb test/integration/web/project_repo_card_test.rb test/integration/web/project_attachments_test.rb test/integration/web/project_page_test.rb test/stimulus_hygiene_test.rb test/css_hygiene_test.rb test/ci_hygiene_test.rb` → 0 failures. **`ci_hygiene_test.rb` is in that list on purpose**: it fails the build if a `@codemirror/*` importmap pin appears, and this task's whole CodeMirror story is that none is needed.

- [ ] **Step 13: mutation checks, four.**
  - (i) In `Projects::ReadmesController#update` delete the `body.strip.empty?` refusal → **"a blank body is refused rather than emptying the README" FAILS**, and the README on disk becomes `"  "`. Restore.
  - (ii) In `Maker::TextSave.call`'s invocation replace `node: row&.node` with `node: nil` → **"saving an existing README rewrites it in place" FAILS** with `FileLayer::UnsupportedOperation` reaching the clobber rescue and the flash reading "A README appeared…". Restore.
  - (iii) In `_readme_editor.html.erb` remove `disabled: true` from the textarea → **"a folder with a README offers an Edit control…" FAILS** on `textarea[name=content][disabled=disabled]`. Restore.
  - (iv) In `readme_controller.js` delete the body of `sync()` — this one is NOT caught by any test in this task, and that is the finding to report: the request tests post `content` directly and never drive CodeMirror. **Record it in the task's review and leave `sync()` in place**; the browser-level guard for it is Task F's phone sweep, which opens the editor but does not type. State this gap plainly rather than inventing a test that does not exercise it.
  Report all outputs.

- [ ] **Step 14: commit.**

```bash
git add config/routes.rb app/controllers/projects_controller.rb app/controllers/projects/readmes_controller.rb app/services/maker/readme.rb app/javascript/controllers/readme_controller.js app/views/projects/_readme_editor.html.erb app/views/shared/_no_history_note.html.erb app/views/projects/_readme_card.html.erb app/views/projects/_repo_card.html.erb app/views/projects/_file_tree_section.html.erb app/views/projects/_attachments.html.erb app/assets/stylesheets/pages/projects.css test/integration/web/readme_edit_test.rb test/services/maker/readme_test.rb
git commit -m "A README can be written on the project page, from a template, with the no-history trade named on the editor"
```

---

### Task D: the owner's preview of their public page

Starts after C has committed.

**Files:**
- Create: `app/views/public/projects/_page.html.erb`, `app/views/projects/preview.html.erb`, `app/views/projects/_preview_banner.html.erb`
- Modify: `app/views/public/projects/show.html.erb`, `config/routes.rb`, `app/controllers/projects_controller.rb`, `app/assets/stylesheets/pages/projects.css`
- Test: new `test/integration/web/project_preview_test.rb`; run `test/integration/web/public_project_test.rb` **unchanged**

- [ ] **Step 1: the failing tests.** Create `test/integration/web/project_preview_test.rb`:

```ruby
require "test_helper"
require "support/public_fixture"

module Web
  # STAGE 4, S4-4 (story 5.1): the maker's own preview of their public page, at ANY visibility.
  #
  # A SESSION-AUTHED ROUTE IN THE PRIVATE NAMESPACE (spec §7). Public::BaseController is untouched:
  # it still 404s a private project to everyone including its owner, and this page reaches the same
  # partials over the same Maker::PublicProject without going through it.
  class ProjectPreviewTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user, visibility: "private")
      @project = @f[:project]
      sign_in_as(@user)
    end

    test "a private project previews for its owner, inside the app shell, behind a banner" do
      get preview_project_path(@project)

      assert_response :success
      assert_select ".preview-banner", /Not published/
      assert_select "aside.rail"
      assert_select "nav.tabbar"
      assert_select ".public-files"
    end

    test "the same project is still a 404 on the public route, to its owner too" do
      get public_project_path("ada", @project.slug)

      assert_response :not_found
    end

    test "the preview's file links are the PUBLIC urls, byte for byte what a visitor would get" do
      get preview_project_path(@project)

      assert_select "a[href=?]", public_file_path("ada", @project.slug, @f[:base].node_id)
    end

    test "a published project's banner says so and names the URL" do
      @project.update!(visibility: "public")

      get preview_project_path(@project)

      assert_select ".preview-banner", /Published/
      assert_select ".preview-banner a[href=?]", public_project_path("ada", @project.slug)
    end

    test "an unlisted project's preview carries the token on every link, as the public page does" do
      @project.update!(visibility: "unlisted")

      get preview_project_path(@project)

      assert_select "a[href=?]", public_file_path("ada", @project.slug, @f[:base].node_id,
                                                  k: @project.reload.unlisted_token)
    end

    test "with no handle there is no URL to preview, and the refusal says where to get one" do
      @project.update!(visibility: "private")
      @user.update!(handle: nil)

      get preview_project_path(@project)

      assert_redirected_to project_path(@project)
      assert_match(/handle/i, flash[:alert])
    end

    test "another maker's project is a 404" do
      other = make_owner!(handle: "bob")
      theirs = other.maker_projects.create!(name: "Theirs")

      get preview_project_path(theirs)

      assert_response :not_found
    end
  end
end
```

- [ ] **Step 2: run, expect FAIL.** `bin/rails test test/integration/web/project_preview_test.rb` → `undefined local variable or method 'preview_project_path'`.

- [ ] **Step 3: extract `public/projects/_page.html.erb`.** This is a **pure move**, and `public_project_test.rb`'s 23 tests are the guard that it changed nothing — do not edit them.

  Cut everything in `app/views/public/projects/show.html.erb` from `<nav class="breadcrumb" aria-label="Project path">` (line 41) to the end of the file into the new `app/views/public/projects/_page.html.erb`, then in the moved text replace `@pub` with `pub` and `@project` with `project` throughout. Keep every comment verbatim. The new file opens with:

```erb
<%#
  ONE PUBLISHED PROJECT'S PAGE BODY (stage 3, S3-4; extracted stage 4, S4-4). Two callers render
  it: public/projects/show.html.erb (the visitor's page) and projects/preview.html.erb (the
  OWNER's preview of it, behind a banner, at any visibility — spec §7). Extracted rather than
  copied for the reason Maker::ProjectPhotos was: two surfaces claiming to show "what a visitor
  sees" that are two templates are a pair that drifts, and the drift is invisible until a maker
  publishes something the preview never showed them.

  IT READS `pub` AND NOTHING ELSE. No ivars, no session, no `current_user` — which is what lets the
  same markup render under Public::BaseController (ActionController::Base, no session at all) and
  under ProjectsController without a branch. Its `content_for` blocks stayed behind in show.html.erb
  on purpose: the noindex meta and the Atom <link> are the PUBLIC page's head, not the preview's.

  Local: pub (Maker::PublicProject).
%>
<% project = pub.project %>
```

  `show.html.erb` keeps its `content_for :title` and its two `content_for :head` blocks and ends with:

```erb
<%= render "public/projects/page", pub: @pub %>
```

- [ ] **Step 4: run the public suites, expect PASS with NO edits.** `bin/rails test test/integration/web/public_project_test.rb test/integration/web/public_bundle_test.rb test/integration/web/public_feed_test.rb test/integration/web/gerber_preview_test.rb test/integration/web/project_releases_test.rb` → 0 failures. **If any assertion needs changing, the "move" was not a move — find the difference before going on.**

- [ ] **Step 5: the route.** In `config/routes.rb`, inside `resources :projects do`, beside the existing `patch :unarchive, on: :member`:

```ruby
    # THE OWNER'S PREVIEW OF THEIR PUBLIC PAGE (stage 4, S4-4; story 5.1). A member GET on THIS
    # controller, not a door into Public:: — spec §7: `Public::` never reads the session, so the
    # preview is a session-authed route in the private namespace that renders the public partials
    # with a banner, never a bypass in Public::BaseController. `controller_path` is still
    # "projects", so ShellHelper::SECTIONS needs no entry and the rail still lights Projects.
    get :preview, on: :member
```

- [ ] **Step 6: the action.** In `app/controllers/projects_controller.rb`, add `preview` to the `before_action :set_project` list, and add the action after `#show`:

```ruby
  # GET /projects/:id/preview — what a visitor sees, at any visibility, for the owner (story 5.1).
  #
  # THE SAME OBJECT THE PUBLIC PAGE USES, BUILT DIRECTLY. Maker::PublicProject takes the project
  # alone, reads `project.user` for every query and port call, and consults no session anywhere —
  # so building one here needs no change to Public::BaseController and no session-aware branch
  # inside it. What this route does NOT do is relax the public gate: /u/:handle/:slug still 404s a
  # private project to everyone, its owner included, and project_preview_test.rb asserts both
  # halves in the same file so the pair cannot drift.
  #
  # THE LINKS ARE THE VISITOR'S, NOT THE OWNER'S. `Maker::PublicProject#file_url_for` is the ONE
  # answer to "where does this file's link point" — the reason that class exists — so the preview
  # does not rewrite them to /files/:id. For an unlisted or public project they work identically
  # for the maker and for a stranger, which is the case a maker previews for; for a private one
  # they 404, which is precisely what a visitor gets, and the banner says so.
  #
  # NO HANDLE, NO PREVIEW. Every URL on the page is /u/<handle>/<slug>, and `public_file_path(nil,
  # …)` raises UrlGenerationError against the route's own handle constraint. Maker::Project already
  # refuses to PUBLISH without a handle; refusing to preview is the same rule, and the alert points
  # at the panel that claims one rather than at a dead end.
  def preview
    if current_user.handle.blank?
      return redirect_to project_path(@project),
                         alert: "Choose a handle first — a public page lives at /u/<handle>/#{@project.slug}. " \
                                "You can claim one in the Publish panel."
    end

    @pub = Maker::PublicProject.new(@project)
  end
```

- [ ] **Step 7: the two templates.**

`app/views/projects/_preview_banner.html.erb`:

```erb
<%#
  WHAT THIS PAGE IS (stage 4, S4-4; story 5.1). The preview renders the visitor's page inside the
  MAKER's shell, so without a banner it is a page that looks published and is not. Three states,
  and each says what is true of the LINKS on the page below it, because that is the part a maker
  is about to be surprised by.

  Local: project.
%>
<div class="preview-banner">
  <p>
    <strong>Preview</strong> — this is what a visitor sees.
    <% if project.publicly_listed? %>
      Published: it is listed at <%= link_to "/explore", public_explore_path %> and on your handle page.
    <% elsif project.unlisted? %>
      Published as unlisted: anyone with the link can open it; it is listed nowhere.
    <% else %>
      <strong>Not published.</strong> Nothing here is reachable yet, so the links on this page do not work.
    <% end %>
  </p>
  <p>
    <% if project.published? %>
      <%= link_to "Open the real page",
                  public_project_path(project.user.handle, project.slug,
                                      **(project.unlisted? ? { k: project.unlisted_token } : {})),
                  class: "linkbtn small" %>
    <% end %>
    <%= link_to "Back to the project", project_path(project), class: "linkbtn small" %>
  </p>
</div>
```

`app/views/projects/preview.html.erb`:

```erb
<% content_for :crumbs do %>
  <nav class="breadcrumb" aria-label="Project path">
    <%= link_to "Projects", projects_path %>
    <span class="sep" aria-hidden="true">/</span>
    <%= link_to @project.name, project_path(@project) %>
    <span class="sep" aria-hidden="true">/</span>
    <span aria-current="page">Preview</span>
  </nav>
<% end %>

<%= render "projects/preview_banner", project: @project %>
<%= render "public/projects/page", pub: @pub %>

<%#
  THE TITLE IS SET LAST, AND `flush:` IS WHY. `content_for` APPENDS, and the partial above sets no
  title — but the day it does, an earlier `content_for :title` here would render as the two titles
  concatenated. The layout is rendered AFTER this template either way (the body becomes
  content_for(:layout) first), so a title written at the bottom reaches <title> exactly as one
  written at the top would; only the append order differs. Never write a percent-greater-than
  sequence inside one of these comments — an ERB comment ends at the first one and the rest of the
  prose prints into the page (§14d).
%>
<% content_for :title, "Preview — #{@project.name} — Tinkerex", flush: true %>
```

- [ ] **Step 8: the CSS.** Append inside `pages/projects.css`'s `@layer pages` block, after the README editor block:

```css
  /* --- The preview banner (stage 4, S4-4): the one thing on the preview that a visitor never
     sees, so it must not look like part of the page it sits above. --- */
  .preview-banner { border: 1px solid var(--accent); border-radius: var(--radius-panel);
                    background: color-mix(in srgb, var(--accent) 8%, var(--surface));
                    padding: 10px 14px; margin: 0 0 16px;
                    display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; }
  .preview-banner p { margin: 0; flex: 1 1 320px; font-size: 13px; }
  .preview-banner p:last-child { flex: 0 0 auto; display: flex; gap: 8px; }
```

- [ ] **Step 9: run, expect PASS.** `bin/rails test test/integration/web/project_preview_test.rb test/integration/web/public_project_test.rb test/architecture_invariants_test.rb test/css_hygiene_test.rb` → 0 failures. `architecture_invariants_test.rb` is in the list because it scans `app/views/public/**` for session words — the extracted partial must still name none.

- [ ] **Step 10: mutation checks, three.**
  - (i) Delete the `current_user.handle.blank?` guard in `#preview` → **"with no handle there is no URL to preview" FAILS** with `ActionController::UrlGenerationError` out of `public_file_path`, which is the failure the guard exists to convert into a sentence. Restore.
  - (ii) In `_preview_banner.html.erb` replace the whole `if/elsif/else` with the published arm alone → **"a private project previews for its owner, inside the app shell, behind a banner" FAILS** on `/Not published/`. Restore.
  - (iii) In `Public::BaseController#public_project!` change `.published` to `.all` — the mutation that would make the preview redundant by opening the public route → **"the same project is still a 404 on the public route, to its owner too" FAILS**, and so does `public_project_test.rb`'s own private-project test. Restore. This one proves the preview is not quietly a gate relaxation.
  Report all outputs.

- [ ] **Step 11: commit.**

```bash
git add config/routes.rb app/controllers/projects_controller.rb app/views/projects/preview.html.erb app/views/projects/_preview_banner.html.erb app/views/public/projects/_page.html.erb app/views/public/projects/show.html.erb app/assets/stylesheets/pages/projects.css test/integration/web/project_preview_test.rb
git commit -m "A maker can see their own public page before anyone else does, at any visibility"
```

---

### Task E: the Publish panel

Starts after D has committed.

**Files:**
- Create: `app/views/projects/_publish.html.erb`, `app/controllers/projects/unlisted_tokens_controller.rb`, `app/javascript/controllers/copy_controller.js` (**only if absent** — decision 9)
- Modify: `config/routes.rb`, `app/controllers/projects_controller.rb` (`#update`), `app/controllers/settings/handles_controller.rb`, `app/views/projects/show.html.erb`, `app/views/projects/_form.html.erb`, `app/assets/stylesheets/pages/projects.css`
- Test: new `test/integration/web/publishing_test.rb`; edit `test/integration/web/project_publishing_form_test.rb`, `test/integration/web/settings_handle_test.rb`

- [ ] **Step 1: the failing tests.** Create `test/integration/web/publishing_test.rb`:

```ruby
require "test_helper"

module Web
  # STAGE 4, S4-4 (stories 5.2, 5.8): the Publish panel on the project page — the ONE place
  # visibility and licence are set, with the meanings spelled out, the handle claimable inline, the
  # URL copyable, and the unlisted link rotatable.
  class PublishingTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "publish-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    # --- the panel -----------------------------------------------------------------------------

    test "with a handle the panel offers three visibility rows with their meanings, under the name the controller permits" do
      @user.update!(handle: "chaim")

      get project_path(@project)

      assert_select "section.publish-panel#publish" do
        assert_select "input[type=radio][name=?]", "project[visibility]", 3
        assert_select "input[type=radio][name=?][value=private][checked=checked]", "project[visibility]"
        assert_select ".publish-option", text: /only you/i
        assert_select ".publish-option", text: /anyone with the link/i
        assert_select ".publish-option", text: /listed at \/explore/i
        assert_select "select[name=?]", "project[license]"
        assert_select "input[type=hidden][name=return_to][value=project]"
      end
    end

    test "the page head links to the panel" do
      get project_path(@project)
      assert_select ".page-head a[href='#publish']"
    end

    test "with no handle the panel claims one inline and offers no visibility rows" do
      get project_path(@project)

      assert_select "section.publish-panel form[action=?]", settings_handle_path do
        assert_select "input[name=?]", "user[handle]"
        assert_select "input[type=hidden][name=project_id][value=?]", @project.slug
      end
      assert_select "section.publish-panel input[type=radio][name=?]", "project[visibility]", 0
    end

    test "a published project shows its URL with a copy control" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "public")

      get project_path(@project)

      url = public_project_url(@project.user.handle, @project.slug)
      assert_select ".publish-url [data-controller=copy][data-copy-text-value=?]", url
      assert_select ".publish-panel a[href=?]", preview_project_path(@project), text: "Preview"
    end

    test "an unlisted project shows the token link with copy and a New link button" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "unlisted")

      get project_path(@project)

      url = public_project_url("chaim", @project.slug, k: @project.reload.unlisted_token)
      assert_select ".publish-unlisted [data-controller=copy][data-copy-text-value=?]", url
      assert_select "form[action=?]", project_unlisted_token_path(@project)
    end

    # --- the save ------------------------------------------------------------------------------

    test "publishing names the URL and what became downloadable" do
      @user.update!(handle: "chaim")

      patch project_path(@project), params: { project: { visibility: "public" }, return_to: "project" }

      assert_redirected_to project_path(@project)
      assert_match %r{/u/chaim/desk-lamp}, flash[:notice]
      assert_match(/downloadable/, flash[:notice])
    end

    test "unpublishing says the public page is gone" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "public")

      patch project_path(@project), params: { project: { visibility: "private" }, return_to: "project" }

      assert_match(/private again/, flash[:notice])
    end

    test "a change that is not a visibility change keeps the old wording" do
      patch project_path(@project), params: { project: { name: "Lamp" } }
      assert_equal "Project updated.", flash[:notice]
    end

    test "a refusal from the panel lands back on the project page, not on the edit form" do
      patch project_path(@project), params: { project: { visibility: "public" }, return_to: "project" }

      assert_redirected_to project_path(@project)
      assert_match(/handle/i, flash[:alert])
      assert_equal "private", @project.reload.visibility
    end

    # --- the unlisted token --------------------------------------------------------------------

    test "New link mints a new token and says the old one stopped working" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "unlisted")
      before = @project.reload.unlisted_token

      post project_unlisted_token_path(@project)

      assert_redirected_to project_path(@project)
      assert_not_equal before, @project.reload.unlisted_token
      assert_match(/\A\h{32}\z/, @project.unlisted_token)
      assert_match(/no longer work/, flash[:notice])
    end

    test "the old link stops working the moment it is rotated" do
      @user.update!(handle: "chaim")
      @project.update!(visibility: "unlisted")
      old = @project.reload.unlisted_token

      post project_unlisted_token_path(@project)
      delete destroy_user_session_path

      get public_project_path("chaim", @project.slug, k: old)
      assert_response :not_found
      get public_project_path("chaim", @project.slug, k: @project.reload.unlisted_token)
      assert_response :success
    end

    test "a project that is not unlisted has no link to rotate" do
      @user.update!(handle: "chaim")

      post project_unlisted_token_path(@project)

      assert_redirected_to project_path(@project)
      assert_match(/unlisted/, flash[:alert])
    end

    # --- the inline handle claim ---------------------------------------------------------------

    test "claiming a handle from the panel returns to the project" do
      patch settings_handle_path, params: { user: { handle: "chaim" }, project_id: @project.slug }

      assert_redirected_to project_path(@project)
      assert_equal "chaim", @user.reload.handle
    end

    test "a refused claim from the panel also returns to the project" do
      patch settings_handle_path, params: { user: { handle: "x" }, project_id: @project.slug }

      assert_redirected_to project_path(@project)
      assert_match(/Handle/, flash[:alert])
    end

    test "another maker's slug in project_id falls back to the account page" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")

      patch settings_handle_path, params: { user: { handle: "chaim" }, project_id: theirs.slug }

      assert_redirected_to edit_user_registration_path
    end
  end
end
```

- [ ] **Step 2: move the four form tests out of `project_publishing_form_test.rb`.** Delete its first three tests (`the edit form renders both selects…`, `without a handle the form points at the account page`, `with a handle the hint is gone`) — the panel's equivalents are in `publishing_test.rb` above. Keep the four save/badge tests and update the file header:

```ruby
  # THE PUBLISHING SAVE (stage 3, S3-4; the panel arrived in stage 4, S4-4). The Visibility and
  # Licence CONTROLS moved to projects/_publish.html.erb — one column, one control (§14a's
  # one-question-two-answers rule) — and their rendered-field assertions moved with them to
  # publishing_test.rb. What stays here is `project_params` actually permitting the two, the
  # handle-required refusal on the EDIT form's own path, and the page-head badge.
```

- [ ] **Step 3: run, expect FAIL.** `bin/rails test test/integration/web/publishing_test.rb` → fails on `project_unlisted_token_path` first.

- [ ] **Step 4: routes.** In `config/routes.rb`, inside `resources :projects do`, after `resource :readme`:

```ruby
    # A NEW UNLISTED LINK (stage 4, S4-4; story 5.8). SINGULAR and create-only: there is one token,
    # rotating it is a verb with no id, and there is nothing to GET — the link is on the project
    # page. `mint_unlisted_token` only ever FILLED a nil column, so until now a link handed out
    # once worked forever with no way to withdraw it.
    resource :unlisted_token, only: :create, module: :projects
```

- [ ] **Step 5: the rotation door.** Create `app/controllers/projects/unlisted_tokens_controller.rb`:

```ruby
module Projects
  # POST /projects/:project_id/unlisted_token — mint a new unlisted link and break the old one
  # (stage 4, S4-4; story 5.8). Session-authed web layer (§14d).
  class UnlistedTokensController < ApplicationController
    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      unless project.unlisted?
        return redirect_to project_path(project),
                           alert: "Only an unlisted project has a link to replace."
      end

      # `update!`, NOT `update_column`. The callback that fills this column is a `||=` on a nil, so
      # it cannot interfere; what `update!` buys is the validations — a row that has drifted into an
      # unpublishable state must not be quietly written past on its way to a new credential.
      project.update!(unlisted_token: SecureRandom.hex(16))
      redirect_to project_path(project),
                  notice: "New unlisted link. Anyone holding the old one will no longer work."
    end
  end
end
```

- [ ] **Step 6: `#update` says what publishing did.** In `app/controllers/projects_controller.rb`:

```ruby
  def update
    if @project.update(project_params)
      redirect_to project_path(@project), notice: publish_notice
    else
      # THE PANEL POSTS THE SAME TWO FIELDS AS THE EDIT FORM (stage 4, S4-4), and there is no edit
      # page behind it — a refusal that re-rendered :edit would bounce a maker off the page they
      # clicked on, into a form whose visibility field no longer exists. `return_to` is NOT a URL:
      # it is the literal string "project", resolved here to THIS project's own path, so there is
      # nothing to sanitise and no open redirect to get wrong (the same reason
      # ApplicationHelper#back_target_path refuses to take a URL param, §14d).
      return redirect_to project_path(@project), alert: @project.errors.full_messages.to_sentence if
        params[:return_to] == "project"

      render :edit, status: :unprocessable_entity
    end
  end
```

and, in the private section:

```ruby
  # WHAT A VISIBILITY CHANGE ACTUALLY DID, IN THE MAKER'S TERMS (stage 4, S4-4; story 5.2). "Project
  # updated." was the whole feedback for publishing until now — no URL, and no word about the fact
  # that EVERY visible file in the project's folder became downloadable by ancestry
  # (Maker::PublicProject#permits?). A maker cannot consent to what nobody told them.
  #
  # `saved_change_to_visibility?` RATHER THAN `published?`: the sentence is about the CHANGE, so a
  # save that touched the name must not re-announce a publication that happened last week.
  def publish_notice
    return "Project updated." unless @project.saved_change_to_visibility?
    return "#{@project.name} is private again. Its public page is gone." unless @project.published?

    url = public_project_url(@project.user.handle, @project.slug,
                             **(@project.unlisted? ? { k: @project.unlisted_token } : {}))
    who = @project.unlisted? ? "anyone with that link" : "anyone"
    "Published at #{url}. Everything in the project's folder is now downloadable by #{who}."
  end
```

- [ ] **Step 7: the handle claim can come back to a project.** In `app/controllers/settings/handles_controller.rb`, replace the two redirect targets with a resolved one and add:

```ruby
    # WHERE A CLAIM RETURNS TO (stage 4, S4-4). The Publish panel claims a handle inline, and
    # bouncing a maker to the Account page mid-publish loses the thing they were doing. The param
    # is a project SLUG, not a path: it is looked up in `current_user`'s own projects and turned
    # into a route here, so an unknown or someone else's slug falls back to the Account page rather
    # than redirecting anywhere a caller named. There is no URL in this parameter to sanitise.
    def return_path
      slug = params[:project_id].presence
      project = slug && current_user.maker_projects.find_by(slug:)
      project ? project_path(project) : edit_user_registration_path
    end
    private :return_path
```

with `#update` becoming:

```ruby
    def update
      current_user.handle = params.require(:user).permit(:handle)[:handle]
      if current_user.save
        redirect_to return_path, notice: "Your handle is @#{current_user.handle}."
      else
        redirect_to return_path, alert: "Handle #{current_user.errors[:handle].first}."
      end
    end
```

- [ ] **Step 8: the panel.** Create `app/views/projects/_publish.html.erb`:

```erb
<%#
  PUBLISHING, IN ONE PLACE, IN PLAIN LANGUAGE (stage 4, S4-4; stories 5.1, 5.2, 5.8). Until now
  visibility and licence were two bare selects on the EDIT form and the feedback was "Project
  updated." — four clicks with a handle, about seven without, and nothing anywhere said that
  publishing makes every visible file in the folder downloadable.

  THIS IS THE ONLY PLACE EITHER COLUMN IS SET. They were removed from projects/_form.html.erb in
  the same change: one column with two controls is the shape §14a keeps recording, and only this
  one can carry the meanings.

  THE LAST PANEL, WITH A LINK IN THE PAGE HEAD. The head already carries the visibility badge and
  the public link, so that is where a maker looks for publishing state; a settings box above the
  maker's own content on every render would give prime space to a surface most projects never use
  (spec §2.3). The `id` is what the head's anchor targets.

  `scope: :project` — form_with over a NAMESPACED model would otherwise name the fields
  `maker_project[...]`, which ProjectsController's `params.require(:project)` rejects and every
  save would silently drop (§14d, shipped twice). Asserted as RENDERED in publishing_test.rb.

  Local: project.
%>
<section class="panel publish-panel" id="publish">
  <div class="panel-head">
    <h2>Publish</h2>
    <%= link_to "Preview", preview_project_path(project), class: "linkbtn small" %>
  </div>

  <% if project.user.handle.blank? %>
    <%# A HANDLE BEFORE A URL: the public page lives at /u/<handle>/<slug>, so with none there is
        nothing to publish TO and Maker::Project refuses the save. Claimed here rather than on the
        Account page two navigations away — the same door (Settings::HandlesController), told where
        to come back to by a project SLUG it resolves itself. %>
    <p class="muted">Public projects live at <code>/u/&lt;handle&gt;/<%= project.slug %></code>. Choose a handle to publish.</p>
    <%= form_with url: settings_handle_path, method: :patch, scope: :user, class: "handle-form" do |f| %>
      <%= hidden_field_tag :project_id, project.slug %>
      <label class="field">
        <span>Handle</span>
        <%= f.text_field :handle, placeholder: "e.g. chaim", autocomplete: "off",
                         pattern: "[a-z0-9][a-z0-9-]{0,30}[a-z0-9]" %>
      </label>
      <%= f.submit "Claim handle", class: "btn small" %>
    <% end %>
  <% else %>
    <%= form_with model: project, scope: :project, url: project_path(project), method: :patch,
                  class: "publish-form" do |f| %>
      <%= hidden_field_tag :return_to, "project" %>
      <fieldset class="publish-options">
        <legend>Who can see this</legend>
        <% [ [ "private",  "Private",  "Only you." ],
             [ "unlisted", "Unlisted", "Anyone with the link. Not listed anywhere." ],
             [ "public",   "Public",   "Listed at /explore and on your handle page." ] ].each do |value, label, meaning| %>
          <label class="publish-option">
            <%= f.radio_button :visibility, value %>
            <span class="publish-option-label"><%= label %></span>
            <span class="muted publish-option-meaning"><%= meaning %></span>
          </label>
        <% end %>
      </fieldset>

      <label class="field">
        <span>License</span>
        <%= f.select :license,
                     options_for_select([ [ "None", "" ] ] + Maker::Project::LICENSES.map { |id, l| [ "#{l} (#{id})", id ] },
                                        project.license) %>
      </label>

      <%# EVERYTHING IN THE FOLDER, NOT JUST WHAT IS ON THE PAGE. Permission is by ANCESTRY
          (Maker::PublicProject#permits?), so a file past the listing's cap is still downloadable.
          Said before the button, not in the flash afterwards. %>
      <p class="muted publish-warning">Publishing makes every visible file in
        <span class="mono"><%= Maker::ProjectFolders::ROOT %>/<%= project.slug %></span> downloadable by anyone who can open the page.</p>

      <div class="form-actions">
        <%= f.submit "Save publishing", class: "btn small primary" %>
      </div>
    <% end %>

    <% if project.published? %>
      <% url = public_project_url(project.user.handle, project.slug) %>
      <div class="publish-url">
        <span class="mono"><%= url %></span>
        <button type="button" class="btn small" data-controller="copy" data-copy-text-value="<%= url %>"
                data-action="copy#copy">Copy</button>
      </div>
    <% end %>

    <% if project.unlisted? %>
      <% link = public_project_url(project.user.handle, project.slug, k: project.unlisted_token) %>
      <div class="publish-unlisted">
        <p class="muted">The link IS the credential — anyone holding it can open the page.</p>
        <span class="mono"><%= link %></span>
        <button type="button" class="btn small" data-controller="copy" data-copy-text-value="<%= link %>"
                data-action="copy#copy">Copy</button>
        <%= button_to "New link", project_unlisted_token_path(project), method: :post, class: "btn small",
                      form: { data: { turbo_confirm: "Replace the link? Anyone holding the old one loses access." } } %>
      </div>
    <% end %>
  <% end %>
</section>
```

- [ ] **Step 9: the page head link and the panel's place.** In `app/views/projects/show.html.erb`:

(a) inside `.page-title`, after the `if @project.published?` block's `end`:

```erb
    <%# THE DOOR TO THE PANEL (stage 4, S4-4). A plain in-page anchor: the panel is the LAST panel
        so it does not displace the maker's own content, and the head is where a maker already
        looks for publishing state. %>
    <%= link_to (@project.published? ? "Publishing" : "Publish"), "#publish", class: "linkbtn small publish-link" %>
```

(b) as the last line inside `.project-panels`, after `<%= render "sheets" %>`:

```erb
  <%# Stage 4, S4-4: visibility, licence, the URL and the unlisted link — see the partial's header
      for why it is last and why the page head links to it. %>
  <%= render "publish", project: @project %>
```

- [ ] **Step 10: the two fields leave the edit form.** In `app/views/projects/_form.html.erb`, delete the Visibility label (lines 29–33), the handle hint (34–36) and the License label (37–42), and put this in their place:

```erb
  <%# VISIBILITY AND LICENCE MOVED TO THE PUBLISH PANEL (stage 4, S4-4), on the project page, where
      the three states can carry their meanings and a handle can be claimed inline. They are not
      duplicated here: one column with two controls is the shape §14a keeps recording, and
      `project_params` still permits both because the panel posts to this same #update. %>
```

- [ ] **Step 11: the copy controller.** `ls app/javascript/controllers/copy_controller.js`. **If it exists (S4-3 landed first), skip this step entirely.** Otherwise create it:

```js
import { Controller } from "@hotwired/stimulus"

// Copy a string to the clipboard and say so (stage 4, S4-4 / S4-3 — whichever landed first; the
// other reuses this file unchanged). The text is an attribute rather than the element's own
// content because the thing shown and the thing copied are not always the same string.
//
// navigator.clipboard NEEDS A SECURE CONTEXT — https, or localhost. On a plain-http self-hosted
// deployment it is undefined, so the failure is reported in the button rather than thrown into a
// console nobody is reading.
export default class extends Controller {
  static values = { text: String }

  async copy(event) {
    const button = event?.currentTarget ?? this.element
    const original = button.textContent
    try {
      await navigator.clipboard.writeText(this.textValue)
      button.textContent = "Copied"
    } catch {
      button.textContent = "Press ⌘C"
      return
    }
    setTimeout(() => { button.textContent = original }, 1500)
  }
}
```

- [ ] **Step 12: the CSS.** Append inside `pages/projects.css`'s `@layer pages` block:

```css
  /* --- The Publish panel (stage 4, S4-4): three visibility rows that carry their own meaning,
     then the URLs. `.btn` and `.field` are components and are only used here, never redeclared
     (design-system rule 3). --- */
  .publish-panel .publish-options { border: 0; padding: 0; margin: 0 0 12px; display: flex; flex-direction: column; gap: 6px; }
  .publish-panel .publish-options legend { padding: 0; font-size: 13px; font-weight: 600; }
  .publish-option { display: grid; grid-template-columns: auto auto 1fr; align-items: baseline; gap: 4px 8px; }
  .publish-option-label { font-weight: 600; font-size: 13px; }
  .publish-option-meaning { font-size: 12px; }
  .publish-warning { font-size: 12px; }
  .publish-url, .publish-unlisted { display: flex; flex-wrap: wrap; align-items: center; gap: 8px;
                                    margin-top: 12px; padding-top: 12px; border-top: 1px solid var(--line); }
  .publish-url .mono, .publish-unlisted .mono { font-size: 12px; overflow-wrap: anywhere; }
  .publish-unlisted p { flex-basis: 100%; margin: 0; font-size: 12px; }
  .publish-unlisted form { margin: 0; }
```

- [ ] **Step 13: run, expect PASS.** `bin/rails test test/integration/web/publishing_test.rb test/integration/web/project_publishing_form_test.rb test/integration/web/settings_handle_test.rb test/integration/web/projects_flow_test.rb test/integration/web/project_page_test.rb test/models/maker/project_publishing_test.rb test/models/user_handle_test.rb test/stimulus_hygiene_test.rb test/css_hygiene_test.rb` → 0 failures. If `settings_handle_test.rb` has a test asserting the redirect target of a claim with no `project_id`, it must still pass unchanged — `return_path` falls back to exactly the old target.

- [ ] **Step 14: mutation checks, four.**
  - (i) In `publish_notice` replace the whole body with `"Project updated."` → **"publishing names the URL and what became downloadable" FAILS** on `%r{/u/chaim/desk-lamp}`. Restore.
  - (ii) In `#update` delete the `params[:return_to] == "project"` early return → **"a refusal from the panel lands back on the project page" FAILS** with `422` instead of the redirect. Restore.
  - (iii) In `UnlistedTokensController#create` replace `SecureRandom.hex(16)` with `project.unlisted_token` → **"New link mints a new token" FAILS** on `assert_not_equal`, and **"the old link stops working"** fails on the 404. Restore.
  - (iv) In `Settings::HandlesController#return_path` replace the body with `edit_user_registration_path` → **"claiming a handle from the panel returns to the project" FAILS**. Restore.
  Report all outputs.

- [ ] **Step 15: commit.**

```bash
git add config/routes.rb app/controllers/projects_controller.rb app/controllers/projects/unlisted_tokens_controller.rb app/controllers/settings/handles_controller.rb app/views/projects/_publish.html.erb app/views/projects/show.html.erb app/views/projects/_form.html.erb app/javascript/controllers/copy_controller.js app/assets/stylesheets/pages/projects.css test/integration/web/publishing_test.rb test/integration/web/project_publishing_form_test.rb
git commit -m "Publishing is one panel that says what each choice means, names the URL it made, and can replace an unlisted link"
```

*(If `copy_controller.js` already existed, drop it from the `git add` and say so in the commit body.)*

---

### Task F: the cross-cutting guards

Starts after E has committed.

**Files:** `test/integration/web/template_hygiene_test.rb`, `test/integration/web/page_query_budget_test.rb`, `test/system/shell_test.rb`

- [ ] **Step 1: the template sweep reaches every new template.** In `template_hygiene_test.rb`'s `pages` hash, beside the five public entries:

```ruby
        # STAGE 4, S4-4: the owner's preview renders projects/preview.html.erb,
        # projects/_preview_banner.html.erb and public/projects/_page.html.erb. The last is also
        # reached by "public project" above — the point of the extraction — but the first two are
        # reached by nothing else, and an unrendered template is one this sweep cannot see a leaked
        # comment in.
        "project preview" => preview_project_path(@project),
```

  The project page already in `pages` reaches `projects/_publish.html.erb`, `_readme_editor.html.erb` and `shared/_no_history_note.html.erb`: the fixture's `@user` has handle `hygiene` (`:100`), its project has a folder through `project_folder_rows!` and a `README.md` node `n-readme` at that folder's root (`:118`), so `@readme_editable` is true and the editor's **existing-README** branch renders. Add one line after that node so the **template** branch renders too, on the unlisted sibling:

```ruby
      # STAGE 4, S4-4: @unlisted has no folder, so the README card does not render for it. Give it
      # one, with no README file, and projects/_readme_editor's "Write a README" branch renders on
      # its page — the branch nothing else in this fixture reaches.
      project_folder_rows!(@user, @unlisted)
```

  and add `"project (no README)" => project_path(@unlisted),` to `pages`.

- [ ] **Step 2: run, expect PASS.** `bin/rails test test/integration/web/template_hygiene_test.rb` → 0 failures, with no template named as uncovered. **If a new template is reported uncovered, fix the fixture, never the assertion.**

- [ ] **Step 3: the preview's query budget, over the public page's own seed.** In `page_query_budget_test.rb`, extract the `public projects#show` fixture into a private method and add the preview's test.

  (a) Cut the four lines from `@user.update!(handle: "budgeted")` through `bom = project.boms.create!(user: @user)` and the whole `add = lambda do |prefix, count| … end` block out of that test, into a private method at the bottom of the class:

```ruby
    # THE PUBLIC PAGE'S SEED, SHARED BY TWO BUDGETS (stage 4, S4-4). `projects#preview` renders the
    # SAME public partials (public/projects/_page) over the SAME Maker::PublicProject, so it must
    # grow the same things. A second copy of this fixture is a pair that drifts, and the preview
    # would then be budgeted against a shape the public page no longer has. Returns [project, add].
    #
    # THE HANDLE IS SET BEFORE THE PROJECT AND THE PROJECT IS CREATED PUBLISHED: Maker::Project
    # refuses to leave `private` without a handle, and the handle then locks. That ordering is the
    # fixture, not a preference.
    def public_page_seed!(handle:, name:, visibility: "public")
      @user.update!(handle:)
      project = @user.maker_projects.create!(name:, status: "active", visibility:)
      folder = project_folder_rows!(@user, project)
      bom = project.boms.create!(user: @user)
      add = lambda do |prefix, count|
        # … the block exactly as it stood in "public projects#show", unchanged …
      end
      [ project, add ]
    end
```

  (b) the public test becomes:

```ruby
    test "public projects#show does not grow with files, entries, BOM lines or connections" do
      delete destroy_user_session_path
      project, add = public_page_seed!(handle: "budgeted", name: "Published")
      assert_constant_queries(public_project_path(@user.handle, project.slug),
                              -> { add.call("ps", SMALL) },
                              -> { add.call("pl", LARGE - SMALL) },
                              "public projects#show")
    end
```

  (c) the new one, directly after it:

```ruby
    # STAGE 4, S4-4: THE OWNER'S PREVIEW, SIGNED IN — which is the difference worth measuring. It
    # renders the same partials over the same object, plus the app shell (the rail, the
    # current-project switcher, the flash) that a visitor never pays for. That shell cost is a
    # CONSTANT and must stay one: a preview that grew with the project would grow with it on a page
    # the maker opens to check their work, not on a page a stranger opens once.
    #
    # NOT SIGNED OUT, unlike every other public budget in this file: this route IS session-authed
    # (spec §7), so measuring it as a visitor would measure a redirect.
    test "projects#preview does not grow with files, entries, BOM lines or connections" do
      project, add = public_page_seed!(handle: "previewed", name: "Previewed", visibility: "private")
      assert_constant_queries(preview_project_path(project),
                              -> { add.call("vs", SMALL) },
                              -> { add.call("vl", LARGE - SMALL) },
                              "projects#preview")
    end
```

- [ ] **Step 4: the project page's budget is unchanged, and prove it.** The Publish panel reads `project.user.handle` and `Maker::Project::LICENSES`; `@readme_row`/`@readme_editable` are in-memory over `@listing`. Nothing new queries and nothing new touches the port. Run `bin/rails test test/integration/web/page_query_budget_test.rb` → PASS on all five existing budgets plus the new one. **Mutation:** in `ProjectsController#show` replace `@readme_row = @listing.available? ? Maker::Readme.row_in(@listing.loose) : nil` with a per-name lookup:

```ruby
    @readme_row = @listing.available? &&
                  Maker::Readme::NAMES.filter_map { |n| current_user.nodes.present.find_by(parent_node_id: @listing.folder_id, name: n) }.first
```

  Run `-n /projects#show/` → **FAILS**, the counts differing by six (one query per README name, per render). Restore; PASS. Report both. *(This is the mutation that proves the "in memory over the listing" claim rather than asserting it in a comment.)*

- [ ] **Step 5: the phone sweep visits the preview and opens the editor.** In `test/system/shell_test.rb`'s signed-in array (`:273-282`), add `preview_project_path(project),` after `project_path(project),`. Add a flag beside `opened_repo`:

```ruby
      # STAGE 4, S4-4: the same gate-on-a-path argument as the two flags above. The preview is the
      # one page in this sweep that renders the PUBLIC partials inside the SIGNED-IN shell, and the
      # README editor is a <details> that mounts CodeMirror only when opened — an unopened one
      # measures a closed summary and says nothing about the editor's width at 375px.
      previewed = false
      opened_readme = false
```

  and inside the loop, beside the existing two branches:

```ruby
        if path == preview_project_path(project)
          assert_selector ".preview-banner"
          previewed = true
        end
        if path == project_path(project)
          # (existing repo/hero/photos assertions stay)
          # STAGE 4, S4-4: open the README editor so this page's overflow check measures a mounted
          # CodeMirror rather than a closed summary, and assert the panel is on the page at all.
          assert_selector "section.publish-panel#publish"
          find(".readme-editor summary").click
          assert_selector ".readme-editor .cm-editor"
          opened_readme = true
        end
```

  and after the loop, beside the two existing asserts:

```ruby
      assert previewed, "the sweep never visited the preview, so its overflow check measured nothing"
      assert opened_readme, "the sweep never opened the README editor, so its overflow check measured a closed summary"
```

  The project in this sweep has a real folder on disk (`:118-121`) but **no README file**, so the editor opens on the template branch with no fetch — which is what makes `assert_selector ".readme-editor .cm-editor"` deterministic here. `assert_no_console_errors ignoring: [ KICANVAS_PLACEHOLDER_FETCH ]` at the end already covers the preview page's KiCanvas embed, which is the same placeholder fetch the public page makes.

- [ ] **Step 6: run the system sweep, expect PASS.** `bin/rails test test/system/shell_test.rb` → 0 failures. **Mutation:** in `pages/projects.css` change `.publish-url .mono, .publish-unlisted .mono` `overflow-wrap: anywhere` to `normal`; run → **the phone sweep FAILS** on `/projects/desk-lamp scrolls sideways at 375px` (a public URL is one unbreakable token). Restore; PASS. Report both. *(Design-system rule 11: long strings get `overflow-wrap: anywhere`; this is the mutation that proves the rule was applied and not just written.)*

- [ ] **Step 7: commit.**

```bash
git add test/integration/web/template_hygiene_test.rb test/integration/web/page_query_budget_test.rb test/system/shell_test.rb
git commit -m "The guards see the new surfaces: the sweep renders them, the budget bounds the preview, the phone opens the editor"
```

---

### Task H: close-out

- [ ] **Step 1: re-tag the stories** in `docs/user-stories.md`, with the new evidence in the last column:
  - **5.1** → `works` — `ProjectsController#preview` renders the public partials for the owner at any visibility, in the app shell behind a banner (S4-4); the public route still 404s a private project to everyone, which `project_preview_test.rb` asserts in the same file.
  - **5.2** → `rough` with new evidence — the Publish panel states each visibility's meaning, warns that the whole folder becomes downloadable, and the flash names the URL and who can now download (S4-4, `projects_controller.rb#publish_notice`); the handle is claimable inline. Still `rough`, not `works`: the handle remains locked once anything is published (`user.rb:185-189`), which is a separate decision nothing in this slice moves.
  - **5.3** → `works` — the README card carries an editor for any project, a template when there is none, and the no-history note on share/s3 (S4-4, `projects/_readme_editor.html.erb`, `Projects::ReadmesController`).
  - **5.4** → `rough` with new evidence — heading ids survive the sanitizer, normalised to `[a-z0-9-]` (S4-4, `markdown.rb#keep_heading_anchors`), so a `#heading` link resolves. Absolute images are still dropped to alt text and an SVG image still force-downloads: unchanged, and not this slice's.
  - **5.8** → `works` — the unlisted link is shown, copyable, and replaceable (S4-4, `Projects::UnlistedTokensController`).
  - **2.13** stays `rough`, with one sentence added naming why: D3's exception landed for the project README only (S4-4, `docs/invariants/git-editing.md`); any text file outside a repository is still refused, and widening it needs its own slice.
  Update the Coverage table's counts.
- [ ] **Step 2: the overview.** In `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md`, mark the S4-4 row as landed with the PR number. In its "S4-4 — documentation on your own page" territory section, correct the two places this plan diverged: the save door is `Maker::TextSave` shared with `FilesController#update` (the territory list named only `LibraryOutput`), and the preview renders a new `public/projects/_page.html.erb` extracted from `show.html.erb`.
- [ ] **Step 3: the gates.** `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci` green; the three legs' run counts identical (a ±2 assertion flap is `tinkerex#131`; anything structural is a bug — and the two tests here that own a share library, `text_save_test.rb` and `readme_edit_test.rb`, are exactly the mechanism that keeps them identical).
- [ ] **Step 4: commit, push, PR, record.** `git commit -m "S4-4 close-out: the stories re-tagged, the overview corrected"`; `/finish-branch`; then `bin/log arc --from-pr <n>`.

---

## Self-review against the spec (§5's S4-4 row and §7)

| spec item | task |
|---|---|
| a Markdown editor on the project page's README card, **for any project** (D3) | C steps 4–8; both cards mount the same partial |
| a template when none exists | C step 3(a) (`Maker::Readme.template_for`), step 6 |
| the no-history note on share/s3, decided by `versioned?` | C step 6 (`shared/_no_history_note`) |
| a Preview of the public page for the owner at any visibility | D steps 5–7 |
| Publish panel: visibility with plain-language meanings | E step 8 |
| Publish panel: licence | E step 8 (moved out of `_form`, decision 6) |
| Publish panel: inline handle claim | E steps 7–8 |
| Publish panel: the URL with copy | E steps 8, 11 |
| Publish panel: unlisted link copy and rotate | E steps 4, 5, 8 |
| heading anchors kept through the sanitizer | A |
| **§7** `Public::` never reads the session; the preview is session-authed in the private namespace | D step 6; `architecture_invariants_test.rb` run at D step 9 |
| **§7** bytes that land on the share go through the port, `replace:`, no `File.write` | B step 3; mutation at B step 7 |
| git-editing's other rules kept; the exception argued in the invariants file | G |
| query budgets constant in N: project page and preview | F steps 3–4, with the mutation |
| the template sweep renders every new partial and branch | F steps 1–2 |
| the phone sweep visits the preview and the panel | F steps 5–6 |
| `stimulus_hygiene_test.rb` derives the two new controllers from filenames | no edit needed; run at C step 12 and E step 13 |
| the three legs identical; every guard mutation-checked | A6, B7, C13, D10, E14, F4, F6; H step 3 |
| stories re-tagged in the same PR | H |

## Open questions the implementer must not decide alone

1. **`readme_controller.js#sync` has no automated guard** (C step 13(iv)). The request tests post `content` directly and the phone sweep opens the editor without typing, so deleting the method's body leaves everything green while every edit is silently discarded — the exact "green suite over something that never worked" shape §15 names. Closing it needs a system test that types into CodeMirror and asserts the saved bytes, which is a new file (`test/system/readme_edit_test.rb`) and roughly the cost of Task F. **Report the gap; do not add the file without a decision.**
2. **Should the preview link file names to the private file page instead of the dead public URLs for a private project?** Decision 4 says no, and gives the argument. If the orchestrator wants the other answer it is a `link:` strategy threaded through `Maker::PublicProject#file_url_for`, `#readme` and `#repo_cards` — which puts a second answer inside the class that exists to have one. Flagged rather than done.
3. **The Publish panel is the LAST panel** (decision 8). If a reviewer wants it first, it is a one-line move in `show.html.erb` plus the head link becoming redundant — but say so before moving it, because the argument against is spec §2.3's, not layout taste.
4. **`project_publishing_form_test.rb` loses three of its seven tests to `publishing_test.rb`.** The file's remaining four are the save path and the badge. If the orchestrator would rather delete the file and fold all seven into `publishing_test.rb`, that is a cleaner end state and a bigger diff; this plan takes the smaller one.
5. **`copy_controller.js` is created by whichever of S4-3 and S4-4 lands first** (decision 9). If both land in the same window, the second must take the first's file unchanged; a merge that keeps two versions is the failure to watch for.
