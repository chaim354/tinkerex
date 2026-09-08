# Stage 4, S4-5: visitors see what you see — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop:** batch by file, dispatch disjoint tasks in parallel, no spec-compliance stage, one capped quality review per task with its mutations run and their output reported.

**Goal:** Deliver S4-5 of `docs/superpowers/specs/2026-09-07-stage-4-bench-maker-design.md` (§5's S4-5 row, decision **D5** — *bring the existing viewers to the public page as they are*, confirmed). A published project gets a **public file page** carrying the 3D viewer, the Measure view read-only, the Gerber stage, KiCanvas, images, PDF and source — the same partials the private file page renders, pointed at public URLs. Public cards on `/explore` and `/u/:handle` get **covers**, the public project page gets the **hero** S4-1 gave the private one, and the anonymous shell gets a **minimal header** (the site name → `/explore`, the author's handle → `/u/:handle`). Zero schema. Every page's query count stays constant in N.

**Stories moved:** 5.5 (`missing` → `works`), 5.7 (`rough` → `works`).

**Architecture:** one condition, one answer, twice over. `FilePreview` is a new controller concern holding `preview_kind`, `gerber_job?` and `gerber_layers_for` — the `FileDelivery` shape exactly, and for `FileDelivery`'s own stated reason: the two controllers cannot share a superclass (`FilesController < ApplicationController`, `Public::FilesController < ActionController::Base`, §14d). `app/views/files/show.html.erb`'s eight viewer branches become eight **strict-locals** partials under `app/views/files/viewers/`, taking every URL as a local so the private page passes `blob_file_path`/`named_blob_file_path`/`geometry_file_path` and the public page passes `Maker::PublicProject#file_url_for` and the new public geometry route. `Public::FilesController#view` permits through `pub.deliverable!` — the same object `#show` asks, so the page and the byte route still cannot disagree. The public geometry endpoint is a **pure reporter**: it never enqueues, because a visitor's poll must not be a write; the public file **page render** enqueues once, only when no current row exists, which is `FilesController#current_thumbnail`'s shape with `kind: "geometry"`.

**Tech Stack:** Rails 8, Hotwire (the existing `modelviewer` / `measure` / `gerber` / `kicanvas` / `codeview` controllers — **no new Stimulus controller**, so `stimulus_hygiene_test.rb` needs no edit), Minitest, `page_query_budget_test.rb`, `template_hygiene_test.rb`, `architecture_invariants_test.rb`, `content_security_policy_test.rb`.

---

## Amendments (orchestrator review, 2026-09-07) — these override anything below that disagrees

1. **EIGHT viewer partials, not seven.** The brief names `_image _pdf _kicanvas _gerber _code _model3d _measure`. `show.html.erb`'s tail — the `:thumbnail` ready branch, its `pending/processing` branch and the final "No inline preview for this file type." fallback (`app/views/files/show.html.erb:316-328`) — is a real branch the public page needs too (a `.step` file's public page must show its thumbnail). Left inline it becomes one condition with two answers across two pages, the shape §14a forbids. It becomes `files/viewers/_static.html.erb`, locals `kind: thumbnail: download_url: name:`.

2. **The three extension constants MOVE to the concern and `FilesController` keeps ALIAS assignments.** `preview_kind`'s body names `MEASURABLE_EXTS` / `KICANVAS_EXTS` / `GERBER_EXTS`, and **Ruby constant lookup inside a module method is LEXICAL**: left on the controller, those three names resolve to `FilePreview::MEASURABLE_EXTS` and raise `NameError` the first time a `.lbrn2` page renders. So they move, and `FilesController` re-exposes them as `X = FilePreview::X` — the precedent is three lines away, `FilesController::SAFE_INLINE_TYPES = FileDelivery::SAFE_INLINE_TYPES` (`app/controllers/files_controller.rb:97-102`) with its own comment: *"This name stays because it is cited from OUTSIDE this file … and it is the SAME frozen array, not a second definition that could drift."* Eight outside citations exist and must keep resolving: `app/models/maker/filing_rule.rb:26` (`EXT_RE`, not moving), `app/helpers/files_helper.rb:171`, `app/services/maker/gerber_archive.rb:122`, `app/services/maker/public_project.rb:207`, `app/views/projects/_schematics.html.erb:9`, `app/services/maker/previews/gerber.rb:16`, `test/integration/web/kicanvas_preview_test.rb`, `docs/invariants/files-preview.md`. **Identity, not equality, is what a guard can check** — Task A adds one.

3. **The `thumbnails` poll local in the brief does not exist and must not be invented.** `files/show.html.erb` carries **no** `data-controller="thumbs"` on any viewer branch — the poll lives on `files/_list`, `files/_grid`, `projects/_hero`, `projects/_photos` and `projects/_attachment_group`, never on the file page's poster. So there is nothing to pass nil for and nothing to degrade: both pages render the poster the same way, and both are static. Read `app/views/files/show.html.erb:305-310` and `_measure.html.erb:74-83` before disagreeing.

4. **"Drop only Add note" is a non-op.** The Measure bar (`app/views/files/_measure.html.erb:18-58`) holds Measure / paper select / Print all / Download SVG / Reset / ✕ Image and **no note control at all**. Notes are `section.notes-panel`, a sibling of the whole preview row (`show.html.erb:382-415`), which the public page simply does not render. So Measure ships publicly *unchanged*: Print to scale and Download SVG are pure client-side work over a payload the visitor already fetched, and removing them would cost the visitor the one thing 5.5 asks for.

5. **The public geometry route never enqueues; the public file PAGE enqueues once.** `kind: "geometry"` is enqueued in exactly two places today, both in `FilesController#geometry` (`files_controller.rb:398-412`) — nothing else in `app/` or `lib/` creates a geometry row (verified by grep). So a public endpoint that only reports would make Measure work publicly *only* for a file its owner had already measured, which is not a feature. The split that satisfies both rules is the one `ThumbnailMap` already draws with its **required, never defaulted** `backfill:` flag (`thumbnail_map.rb:65-71`): the **render** self-heals, the **poll** must not write. So `Public::FilesController#view` calls `Enqueue.call(kind: "geometry")` **only when `Enqueue.current_preview` returns nil**, and `#geometry` never calls it at all. The `current_preview` guard is load-bearing, not politeness: `Enqueue.call` resets a `failed` row to `pending` and re-enqueues *whenever called* (`docs/invariants/measure-view.md:378-383`), so an unguarded render enqueue would let one visitor reloading a page for a file whose render fails re-enqueue on every reload. Guarded, the work is one job per `(node, content token, renderer revision)`, idempotent — the same bound the public project page's `ThumbnailMap` backfill already accepts. **Open question 1 records the conservative alternative; do not silently take it.**

6. **The `/view` route MUST be declared ABOVE the existing file route, and that is a silent trap otherwise.** `get "u/:handle/:slug/files/:id(/*filename)"` (`config/routes.rb:221`) matches `/u/ada/desk-lamp/files/abc/view` with `filename: "view"` — and `:filename` is decorative to the server, so the visitor would get **the bytes** where the page was meant to be, with a 200 and no error anywhere. Declared first, `/view` wins. Pinned by an `assert_recognizes` in Task B step 3.

7. **The seam guard's Public scan must grow to cover the shared partials.** `test/architecture_invariants_test.rb:1036-1040` globs `app/controllers/public/**` and `app/views/public/**` only. The moment a public page renders `app/views/files/viewers/*`, a `current_user` or a `blob_file_path` in one of those reaches a visitor with the guard green. Task A adds `app/views/files/viewers/**` to the scanned set. This is the invariant's own §14e lesson ("a guard that scans a directory dies silently when the directory leaves") applied in the other direction.

8. **The public README's link lambda stays pointed at the BYTES route.** `Maker::Readme.for`'s block resolves `a[href]` **and** `img[src]` through the one lambda (`app/services/maker/readme.rb:74-77`), and `public_project_test.rb:134` asserts `.readme-panel .markdown img[src=?]` equals `public_file_path`. Repointing it at the view page would turn every inline README image into a link to an HTML page. Not changed in this slice.

9. **COVERS LAND ON `/u/:handle` AND NOT ON `/explore`, AND THE BUDGET TEST IS WHAT DECIDED IT.** The spec's S4-5 row asks for both. `page_query_budget_test.rb:393-407` seeds `explore#index` with **one new owner per project** — which is what `/explore` is — and `Maker::Previews::ThumbnailMap` is per-user by construction: a preview row belongs to its owner (`user.maker_previews`) and the port is asked in the owner's name (§14a, `FileLayer.current.stat_all(user, node_ids:)`). So a cover map on a cross-user list is **two statements per distinct maker**, linear in N, and the budget test would go red the moment its seed grew a cover — which Task C makes it do, deliberately, so the constraint is measured rather than assumed. `/u/:handle` is single-owner and stays constant. **`_project_card` therefore takes `thumb:` which may be nil**, `/u/:handle` passes a real map and `/explore` passes nothing; that is one condition (does this card have a ready cover thumbnail?) answered honestly from each caller's own data, not two answers to one condition. **Consequence: story 5.7 re-tags `rough`, not `works`.** Open question 1 prices the two ways to give `/explore` covers; do not pick one silently.

---

## Decisions on the open questions (orchestrator review, 2026-09-07) — these override the text below

1. **Explore covers: option (a).** Covers ship on `/u/:handle`; `/explore` keeps the placeholder and
   story 5.7 re-tags `rough` with the per-owner-map question named as the remaining friction. The
   budget test proves the constraint; a `CoverMap` is a separate decision, not this slice's.
2. **A visitor's render MAY enqueue one geometry job**, guarded by `current_preview` (idempotent per
   node, content token and renderer build); the poll endpoint never writes. State in the PR that
   this matches the thumbnail backfill the public project page has run on anonymous visits since S3-4.
3. **`_schematics` links stay as planned** (download), with the corrected comment.
4. **No browser-tier CSP test.** `bin/ci system` runs on share only, so it could not see the s3 leg
   either; the per-leg `connect-src` integration assertion is the strongest check available. The PR
   names the bucket CORS rule as the operator step it already is (`docs/DEPLOY.md`).
5. **The phone sweep visits the public file page.** Keep Task C step 10.

When a step below conflicts with a decision here, the decision wins.

## Before you start

- Branch from `main` at `1c41287` (S4-1 through S4-4 all merged; nothing else is in flight in this worktree). Never push to `main`. **S4-4 moved the public project page's BODY into `app/views/public/projects/_page.html.erb`** — `public/projects/show.html.erb` is now forty lines (title, `container_class`, the two `content_for :head` blocks) plus `render "public/projects/page", pub: @pub`, and the owner's preview (`projects/preview.html.erb`) renders the SAME partial behind a banner. So every edit this plan aims at `show.html.erb`'s body (the hero in Task C, anything below the breadcrumb) lands in `_page.html.erb` instead, and the partial names inside it are fully qualified (`render "public/projects/…"`) because a bare name resolves against the rendering CONTROLLER's prefixes — under `projects#preview` it would pick the private twin. The head blocks (`noindex`, the Atom link) stay in `show.html.erb`. `test/integration/web/template_hygiene_test.rb` already lists `"project preview"`, and `architecture_invariants_test.rb`'s Public scan already covers `_page.html.erb`. Line numbers quoted below were measured before S4-2…S4-4 landed and have drifted; anchor on TEXT.
- Tests: `export LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)`; style `bin/ci style`; one full-suite run at a time; from a worktree `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci`. The three legs (`test`, `test-s3`, `test-chunk-remote`) must report identical run counts.
- **Read first, in full:** CLAUDE.md §14d's `Public::` bullet and §14a's `Delivery` bullets; `docs/invariants/files-preview.md` (the `named_blob` rule at :335, `VIEWABLE_3D_EXTS` at :342, the Gerber `.gbrjob`/zip rules at :106-160, `presigned_origin` at :410-422, the poll contract at :440-462); `docs/invariants/measure-view.md:275-390` (the geometry endpoint's two rules and `PAYLOAD_REVISION`); `docs/invariants/design-system.md` (component selectors live in `components.css` alone; `@layer` order).
- **Fixtures.** The new public suites use the same three lines every S3-4 suite uses (`test/support/public_fixture.rb`, header lines 8-18): `@root = use_fresh_share_library!`, `@user = make_owner!(handle: "ada")`, `@f = seed_public_project!(@user)`. That module **pins share** (a `create_node!` fixture has bytes behind it only there) and the test still RUNS on all three legs, which is what keeps the run counts identical. **Never `ensure_library_folder!`** — a real mkdir; use `project_folder_rows!` / `make_project_folder!`.
- **`seed_public_project!` is NOT to be extended.** Four suites assert about its contents (`public_project_test.rb`, `public_file_test.rb`, `public_bundle_test.rb` — which asserts the bundle's whole file list — and `public_feed_test.rb`). The new suite adds its own `.lbrn2`, `.gtl`, `.pdf` and unknown-extension nodes in its own `setup`, after the shared seed.
- The fixture already gives you: `@f[:base]` `models/base.stl` (`:model3d`), `@f[:pic]` `photos/pic.png` (`:image`), `@f[:readme]` `README.md` (`:text`), `@f[:kicad]` `driver.kicad_sch` (`:kicanvas`), `@f[:outsider]` `elsewhere.stl` (a sibling of the folder — the refusal case), `@f[:dotfile]` `.env`, `@f[:entry_photo]` at the library root (the attachment arm of `permits?`).
- `git add` a new file before a mutation check; restore with `git checkout -- <file>`; clear `tmp/cache/bootsnap*` after an equal-length restore; `git status --porcelain` before the next run.
- Helpers and facts you will rely on, each verified by reading:
  - `Maker::PublicProject#file_url_for(node_id, filename: nil, download: false)` (`public_project.rb:331-335`) already merges `link_params`, so an unlisted project's token rides every URL for free.
  - `Maker::PublicProject#deliverable!(node_id)` (`:321-326`) resolves in the OWNER's library then asks `permits?`; a refusal and a nonexistent node are the same `RecordNotFound` on purpose.
  - `Maker::Previews::ThumbnailMap.for(user, node_ids)` backfills unconditionally (`thumbnail_map.rb:46-59`) and `#thumb(node_id)` answers a `Maker::Preview` or nil. The public project page already calls it for every listed node (`public_project.rb:276-278`), so a public render enqueueing thumbnails is precedent, not novelty.
  - `Maker::Previews::Enqueue.current_preview(user:, node_id:, name:, version_id:, kind:)` (`enqueue.rb:188-193`) answers the row for this content AND this renderer build, or nil.
  - `Maker::GerberArchive.for(user:, node:)` (`gerber_archive.rb:83-91`) refuses a nil or over-16MB size before any read and caches by `(node_id, content token)`, nil included. `Maker::ThreeMfManifest.for(user:, node:)` (`three_mf_manifest.rb:86-94`) does the same at 64MB and refuses by name first.
  - Every viewer class (`.model-viewer*`, `.gerber-viewer`, `.measure-*`, `.kicanvas-stage`, `.preview-code`, `.preview-pdf`, `.preview-image`) is defined in `app/assets/stylesheets/pages/preview.css`, which `layouts/application.html.erb:21` links on **every** page including the anonymous branch. **No CSS is needed for the viewers themselves.**
  - The CSP applies to `Public::` pages already: the policy is set on `ActionController::Base`, `connect_src`'s Proc is `instance_exec`'d on the responding controller and only calls `FileLayer.current` (`config/initializers/content_security_policy.rb:53-56`), and the anonymous-nonce fix at `:136-138` is what `content_security_policy_test.rb:109` already drives on a logged-out page. Task B pins it for a public page anyway — see Open question 3.

## File structure

| path | responsibility | task |
|---|---|---|
| new `app/controllers/concerns/file_preview.rb`; `app/controllers/files_controller.rb` (include, three alias constants, the three methods removed); new `app/views/files/viewers/_image.html.erb` `_pdf` `_kicanvas` `_gerber` `_code` `_model3d` `_measure` `_static`; `app/views/files/show.html.erb` (renders them); **delete** `app/views/files/_measure.html.erb`; `test/architecture_invariants_test.rb` (the Public scan grows; the constant-identity guard); `test/integration/web/template_hygiene_test.rb` (three fixture nodes, four page entries) | the shared viewers — **a pure extraction** | **A** |
| `config/routes.rb` (two routes, above the file route); `app/controllers/public/files_controller.rb` (`#view`, `#geometry`); new `app/views/public/files/view.html.erb`; `app/services/maker/public_project.rb` (`#view_url_for`, `#gerber_layers_for`); new `test/integration/web/public_file_view_test.rb`; `test/integration/web/page_query_budget_test.rb` (a `public files#view` case); `test/integration/web/template_hygiene_test.rb` (two public file pages) | the public file page | **B** |
| `app/views/public/projects/_files.html.erb`, `_photos.html.erb` (link the view page); `app/views/public/projects/show.html.erb` (hero); `app/views/public/_project_card.html.erb` (cover); `app/controllers/public/explore_controller.rb`, `public/users_controller.rb` (batched covers); `app/services/maker/public_project.rb` (`#cover_node`); `app/views/layouts/application.html.erb` + new `app/views/layouts/_public_header.html.erb`; `app/helpers/shell_helper.rb` (`public_shell?`); `app/assets/stylesheets/shell.css`, `app/assets/stylesheets/pages/public.css`; `test/integration/web/public_project_test.rb`, `public_explore_test.rb`, `page_query_budget_test.rb` (explore + a new `public users#show` case), `test/system/shell_test.rb` (the public loop) | covers, hero, header, the links into the view page | **C** |
| `docs/invariants/files-preview.md` (the viewer partials are shared; the public page's poster has no poll) | the document this slice falsifies | **D** |
| `docs/user-stories.md` (re-tag 5.5, 5.7 + the coverage table), `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md` (S4-5 row → landed) | close-out | **E** |

**Dependencies and batches.**

1. **A alone, first.** Every other task renders its partials, and it is the one task whose proof is *other suites staying green with no edits*.
2. **B and C in parallel** after A. They share `app/services/maker/public_project.rb` — B adds `#view_url_for` and `#gerber_layers_for` at the end of the public section (above `private`), C adds `#cover_node` directly after `#photo_rows`. Anchor on the neighbouring method name, not a line number. They also share `page_query_budget_test.rb` (B appends after `public projects#show`; C edits `explore#index` and appends `public users#show` at the end of the file). If the batch is run by two agents in one worktree, serialise those two files' edits — one full-suite run at a time regardless (memory: `parallel-agents-one-worktree-rules`).
3. **D**, then **E**.

---

### Task A: the shared viewers — a pure extraction

**Files:**
- Create: `app/controllers/concerns/file_preview.rb`
- Modify: `app/controllers/files_controller.rb`
- Create: `app/views/files/viewers/_image.html.erb`, `_pdf.html.erb`, `_kicanvas.html.erb`, `_gerber.html.erb`, `_code.html.erb`, `_model3d.html.erb`, `_measure.html.erb`, `_static.html.erb`
- Modify: `app/views/files/show.html.erb`
- Delete: `app/views/files/_measure.html.erb`
- Test: `test/architecture_invariants_test.rb`, `test/integration/web/template_hygiene_test.rb`

**The proof this is an extraction and not a rewrite:** `test/integration/web/files_flow_test.rb`, `gerber_preview_test.rb`, `kicanvas_preview_test.rb`, `lbrn_geometry_test.rb`, `file_page_test.rb` and `repo_edit_flow_test.rb` must all stay green **with no edits to any of them**. If one needs an edit, the extraction changed behaviour — fix the extraction, never the test.

- [ ] **Step 1: the concern.** Create `app/controllers/concerns/file_preview.rb`. Move `MEASURABLE_EXTS`, `KICANVAS_EXTS`, `GERBER_EXTS`, `gerber_job?`, `gerber_layers_for`, `gerber_layer_for` and `preview_kind` out of `app/controllers/files_controller.rb` **verbatim, comments and all** (`:1448-1588`), changing exactly two things: `current_user` becomes the `user:` argument, and `named_blob_file_path(...)` becomes a `url:` lambda call.

```ruby
# WHICH VIEWER A FILE'S PAGE GETS, and the Gerber layer list that one of them needs — shared by
# FilesController#show (the maker's own file page) and Public::FilesController#view (a visitor's,
# stage 4, S4-5). ONE ANSWER: a public page that decided for itself which viewer a .gbrjob gets
# would be the one-condition-two-answers divergence §14a forbids, one surface at a time.
#
# IT IS A CONCERN RATHER THAN A SHARED SUPERCLASS FOR `FileDelivery`'S REASON, WHICH IS THE SAME
# REASON: FilesController descends from ApplicationController (session, `authenticate_user!`) and
# Public::FilesController from ActionController::Base, deliberately (§14d). A module is the only
# shape that reaches both.
#
# THE THREE EXTENSION CONSTANTS LIVE HERE AND FilesController RE-EXPOSES THEM, and that is not a
# style choice: constant lookup inside a module method is LEXICAL, so `MEASURABLE_EXTS` in
# #preview_kind below resolves to FilePreview::MEASURABLE_EXTS and nothing else. Left on the
# controller they would raise NameError the first time a .lbrn2 page rendered. The alias assignments
# on FilesController are the SAME frozen objects, never a second literal — `SAFE_INLINE_TYPES`
# three lines from them makes the identical move for the identical reason, and
# architecture_invariants_test.rb asserts object IDENTITY so a re-literal cannot pass.
module FilePreview
  extend ActiveSupport::Concern

  # <the MEASURABLE_EXTS comment from files_controller.rb:1448-1455, verbatim>
  MEASURABLE_EXTS = %w[lbrn lbrn2 mage dxf svg].freeze
  # <the KICANVAS_EXTS comment from :1458-1467, verbatim>
  KICANVAS_EXTS = %w[kicad_sch kicad_pcb].freeze
  # <the GERBER_EXTS comment from :1470-1486, verbatim>
  GERBER_EXTS = Maker::FileAttachment::ROLE_BY_EXT.select { |_ext, role| role == "pcb" }.keys.freeze

  # A JOB FILE'S SIBLINGS ARE RESOLVED IN THE OWNER'S NAME AND THE URL IS THE CALLER'S. `user` is
  # the node's owner, which on the public side is not the person making the request (FileDelivery's
  # own rule); `url` builds the layer's fetch URL, because the private page's is /files/:id/blob/:name
  # and a visitor's is /u/:handle/:slug/files/:id/:name — the two cannot be one literal, and a
  # public page must additionally DROP a sibling the project does not permit. The lambda takes the
  # NODE, not an id, because both callers need its name for the trailing extension.
  FLAT_LIMIT = FilesController::FLAT_LIMIT

  private

  # <the gerber_layers_for doc comment from :1489-1507, verbatim, plus one sentence naming `url:`>
  def gerber_job?(name) = File.extname(name).downcase.delete(".") == "gbrjob"

  def gerber_layers_for(user:, node:, url:)
    return [ gerber_layer_for(node, url) ] unless gerber_job?(node.name)

    listed = Maker::GerberSets.job_layer_names(user:, node:)
    siblings = user.nodes.present.where(parent_node_id: node.parent_node_id, kind: "file")
                   .order(:name).limit(FLAT_LIMIT).to_a
                   .select { |n| GERBER_EXTS.include?(File.extname(n.name).downcase.delete(".")) }
                   .reject { |n| gerber_job?(n.name) }
    named = listed ? siblings.select { |n| listed.include?(n.name) } : siblings
    named = siblings if named.empty?
    named.sort_by(&:name).filter_map { |n| gerber_layer_for(n, url) }
  end

  # nil when the caller's `url` refuses this node — the public side's `permits?` arm. The private
  # side's lambda never answers nil, so `filter_map` above is a no-op there.
  def gerber_layer_for(node, url)
    href = url.call(node)
    href && { name: node.name, url: href }
  end

  # <preview_kind, files_controller.rb:1529-1588, moved verbatim>
  def preview_kind(name)
    ...
  end
end
```

`FLAT_LIMIT` is `FilesController::FLAT_LIMIT` (`files_controller.rb:1146`) and must **not** be re-literalled; if referencing it back into the controller reads badly to the reviewer, move `FLAT_LIMIT` to the concern with the same alias treatment as the three ext lists. Either is acceptable; a second `2000` is not.

- [ ] **Step 2: wire the controller.** In `app/controllers/files_controller.rb`, beside `include FileDelivery` (`:33`):

```ruby
  # WHICH VIEWER, AND A .gbrjob's LAYER LIST — shared verbatim with the sessionless public file page
  # (stage 4, S4-5). See app/controllers/concerns/file_preview.rb; the three extension constants
  # below are re-exposed, not redefined.
  include FilePreview

  MEASURABLE_EXTS = FilePreview::MEASURABLE_EXTS
  KICANVAS_EXTS   = FilePreview::KICANVAS_EXTS
  GERBER_EXTS     = FilePreview::GERBER_EXTS
```

and change `#show`'s one call site (`:483-484`) to pass the private URL builder:

```ruby
      elsif @kind == :gerber
        gerber_layers_for(user: current_user, node: @node,
                          url: ->(n) { named_blob_file_path(n.node_id, filename: n.name) })
      end
```

- [ ] **Step 3: run the private suites, expect PASS with no test edits.**

```bash
bin/rails test test/integration/web/files_flow_test.rb test/integration/web/gerber_preview_test.rb \
  test/integration/web/kicanvas_preview_test.rb test/integration/web/lbrn_geometry_test.rb \
  test/integration/web/file_page_test.rb test/integration/web/repo_edit_flow_test.rb
```
Expect 0 failures, 0 errors. A `NameError: uninitialized constant FilePreview::Maker` here means the constants did not move — re-read Amendment 2.

- [ ] **Step 4: the eight partials.** Each is a **strict-locals** template — the magic comment on line 1 (`<%# locals: (...) %>`). This is the repo's first use and it is deliberate: the whole point of the extraction is that the caller supplies the URLs, and without strict locals a caller that forgets one renders `nil` into an `href` with nothing red anywhere. Rails raises `ActionView::Template::Error … missing local` instead. (Never write `<%= … %>` or a bare `%>` inside an ERB comment — §14d, and `template_hygiene_test.rb` checks the rendered page for both delimiters.)

`app/views/files/viewers/_image.html.erb`:
```erb
<%# locals: (name:, blob_url:) %>
<%# The picture itself, served inline from the byte route — FileDelivery's allowlist is what makes
    that safe (raster types plus PDF; SVG and HTML are forced to an attachment). Shared by the
    maker's file page and a visitor's (stage 4, S4-5): `blob_url` is /files/:id/blob for the owner
    and /u/:handle/:slug/files/:id for a visitor. %>
<img src="<%= blob_url %>" alt="<%= name %>" class="preview-image">
```

`app/views/files/viewers/_pdf.html.erb`:
```erb
<%# locals: (name:, blob_url:) %>
<%# Full PDF preview via the browser's own viewer (served inline from the byte route). SAME-ORIGIN
    IFRAME, WHICH IS WHY THE CSP's frame-ancestors IS 'self' AND NOT 'none' (§14e) — and it stays
    true on the public page, which frames the same app's endpoint. %>
<iframe src="<%= blob_url %>" class="preview-pdf" title="<%= name %> (PDF)"></iframe>
```

`app/views/files/viewers/_kicanvas.html.erb` — the body of `show.html.erb:142-148`, its whole comment block (`:123-141`) kept, with `named_blob_file_path(...)` replaced by `named_url` and `"full"` by `controls`:
```erb
<%# locals: (named_url:, controls:) %>
```

`app/views/files/viewers/_gerber.html.erb` — the body of `show.html.erb:174-216`, its comment block (`:150-173`) kept, with `@gerber_layers` → `layers`, `@gerber_single` → `single`, `@thumbnail` → `thumbnail`, `blob_file_path(@node.node_id, download: 1)` → `download_url`, `@node.name` → `name`:
```erb
<%# locals: (layers:, single:, thumbnail:, download_url:, name:) %>
```

`app/views/files/viewers/_code.html.erb` — the body of `show.html.erb:254-270` (the two `preview-code` divs **only**; the `repo-banner` at `:240-252` stays on the private page, because it is a repository fact and not part of the viewer), comment block `:218-239` kept:
```erb
<%# locals: (blob_url:, ext:, editable:, save_url:, base_token:) %>
```
**Both `data-controller` identifiers stay written out literally and the two divs stay duplicated** — `stimulus_hygiene_test.rb` scans the literal attribute, and an interpolated name resolves to nothing it can check (§14d; the existing comment says so and measured what happened). A public caller passes `editable: false, save_url: nil, base_token: nil`.

`app/views/files/viewers/_model3d.html.erb` — the body of `show.html.erb:281-311`, comment block `:272-280` kept:
```erb
<%# locals: (named_url:, format:, colors:, unit_factor:, thumbnail:, download_url:, name:) %>
```
`named_url` is load-bearing and the comment must keep saying so: Online3DViewer picks its importer from the fetched URL's own trailing extension (`files-preview.md:335`).

`app/views/files/viewers/_measure.html.erb` — `git mv app/views/files/_measure.html.erb app/views/files/viewers/_measure.html.erb`, then replace the four ivar reads with locals (`geometry_file_path(@node.node_id)` → `geometry_url`, `@node.name` → `name`, `blob_file_path(@node.node_id)` → `blob_url`, `@thumbnail` → `thumbnail`, the download link → `download_url`):
```erb
<%# locals: (geometry_url:, name:, blob_url:, thumbnail:, download_url:) %>
```
Add one sentence to its header: the same partial serves a visitor's page, where `geometry_url` is the public reporter route and the payload is fetched from the Active Storage blob URL that route names — read-only in the only sense that matters, since Measure has never had a write control.

`app/views/files/viewers/_static.html.erb` — new (Amendment 1), the body of `show.html.erb:316-328`:
```erb
<%# locals: (kind:, thumbnail:, download_url:, name:) %>
<%# THE TAIL BOTH FILE PAGES SHARE: a server-rendered PNG for a format the browser cannot show raw,
    the honest "still generating" while its job runs, and the download fallback for everything else.
    Extracted with the seven interactive viewers (stage 4, S4-5) rather than left inline, because a
    second copy on the public page is one condition with two answers (§14a) — and the answer that
    would drift is what a .step file's public page shows.

    ON A PUBLIC PAGE NOTHING POLLS, and "Generating preview…" is therefore a statement rather than a
    promise: the sentence is honest (a job IS running — the page render enqueued it) and a reload
    resolves it. The same trade `public/projects/_files` makes by rendering files/_thumb's spinner
    with its animation stopped (pages/public.css). %>
<% if kind == :thumbnail && thumbnail&.status == "ready" && thumbnail.asset.attached? %>
  <img src="<%= url_for(thumbnail.asset) %>" alt="Preview of <%= name %>" class="preview-image">
<% elsif kind == :thumbnail && %w[pending processing].include?(thumbnail&.status) %>
  <div class="preview-fallback muted">
    <p>Generating preview…</p>
  </div>
<% else %>
  <div class="preview-fallback muted">
    <p>No inline preview for this file type.</p>
    <%= link_to "Download #{name}", download_url, class: "btn" %>
  </div>
<% end %>
```

- [ ] **Step 5: `show.html.erb` calls them.** Replace `:115-328`'s branch chain with the identical chain rendering the partials. The `if @info.content_token.nil?` guard and the `repo-banner` block stay where they are.

```erb
  <% if @info.content_token.nil? %>
    <p class="muted">No content yet.</p>
  <% elsif @kind == :image %>
    <%= render "files/viewers/image", name: @node.name, blob_url: blob_file_path(@node.node_id) %>
  <% elsif @kind == :pdf %>
    <%= render "files/viewers/pdf", name: @node.name, blob_url: blob_file_path(@node.node_id) %>
  <% elsif @kind == :kicanvas %>
    <%= render "files/viewers/kicanvas", controls: "full",
               named_url: named_blob_file_path(@node.node_id, filename: @node.name) %>
  <% elsif @kind == :gerber %>
    <%= render "files/viewers/gerber", layers: @gerber_layers, single: @gerber_single,
               thumbnail: @thumbnail, name: @node.name,
               download_url: blob_file_path(@node.node_id, download: 1) %>
  <% elsif @kind == :text %>
    <% if @repo_root %>
      <div class="repo-banner"> … unchanged … </div>
    <% end %>
    <%= render "files/viewers/code", blob_url: blob_file_path(@node.node_id),
               ext: File.extname(@node.name).downcase.delete("."), editable: @editable,
               save_url: file_path(@node.node_id), base_token: @info.content_token %>
  <% elsif @kind == :model3d %>
    <%= render "files/viewers/model3d", name: @node.name,
               named_url: named_blob_file_path(@node.node_id, filename: @node.name),
               format: File.extname(@node.name).downcase.delete("."),
               colors: (@viewer_manifest&.colors || []), unit_factor: (@viewer_manifest&.unit_factor || 1.0),
               thumbnail: @thumbnail, download_url: blob_file_path(@node.node_id, download: 1) %>
  <% elsif @kind == :measure %>
    <%= render "files/viewers/measure", name: @node.name,
               geometry_url: geometry_file_path(@node.node_id),
               blob_url: blob_file_path(@node.node_id), thumbnail: @thumbnail,
               download_url: blob_file_path(@node.node_id, download: 1) %>
  <% else %>
    <%= render "files/viewers/static", kind: @kind, thumbnail: @thumbnail, name: @node.name,
               download_url: blob_file_path(@node.node_id, download: 1) %>
  <% end %>
```
The last branch collapses three `elsif`s into one `else` **and that is behaviour-preserving**: `_static` re-tests `kind == :thumbnail` internally, and the old chain's final `else` was already the catch-all. Add one line to the template's header comment naming `files/viewers/` and saying the public page renders the same eight.

- [ ] **Step 6: run the private suites again, expect PASS, still with no test edits.** Same command as step 3, plus `bin/rails test test/stimulus_hygiene_test.rb test/css_hygiene_test.rb`.

- [ ] **Step 7: the seam guard grows (Amendment 7).** In `test/architecture_invariants_test.rb`, extend the glob at `:1036-1040`:

```ruby
    files = (Dir.glob(ROOT.join("app", "controllers", "public", "**", "*.rb")) +
             Dir.glob(ROOT.join("app", "views", "public", "**", "*.{erb,builder,jbuilder}")) +
             # STAGE 4, S4-5: THE VIEWER PARTIALS ARE SHARED, SO THE SCAN HAS TO REACH THEM. A
             # visitor's file page renders app/views/files/viewers/*, which live OUTSIDE this
             # namespace — a `current_user` or a private route helper in one of them would reach a
             # visitor with this guard green. They take every URL as a strict local precisely so
             # they need not know which page they are on; this is what checks that they don't.
             Dir.glob(ROOT.join("app", "views", "files", "viewers", "*.erb"))).sort
```
and raise the plausibility floor from 10 to **18** in the same edit, naming the eight partials in the message.

- [ ] **Step 8: the constant-identity guard.** Append to `test/architecture_invariants_test.rb`:

```ruby
  # THE THREE EXTENSION LISTS ARE ONE OBJECT, NOT TWO EQUAL ONES (stage 4, S4-5). FilePreview owns
  # them because constant lookup inside a module method is lexical; FilesController re-exposes them
  # because eight places outside that file cite `FilesController::KICANVAS_EXTS` and friends. An
  # `assert_equal` here would pass over a re-literal, which is exactly the drift the alias exists to
  # prevent — so this asserts IDENTITY. `SAFE_INLINE_TYPES` gets the same treatment for the same
  # reason (files_controller.rb:97-102 argues it in prose; this is the guard behind the prose).
  test "the file-preview vocabularies are re-exposed on FilesController, never re-declared" do
    { MEASURABLE_EXTS: FilePreview::MEASURABLE_EXTS,
      KICANVAS_EXTS: FilePreview::KICANVAS_EXTS,
      GERBER_EXTS: FilePreview::GERBER_EXTS }.each do |name, owned|
      assert_same owned, FilesController.const_get(name),
                  "FilesController::#{name} is a SECOND list, not the concern's own — a re-literal " \
                  "passes assert_equal and drifts on the next edit"
    end
    assert_same FileDelivery::SAFE_INLINE_TYPES, FilesController::SAFE_INLINE_TYPES
  end
```

- [ ] **Step 9: the template sweep covers the four new branches.** `template_hygiene_test.rb` derives its template list from the tree and asserts every one is rendered by some page in `pages`; `_image`, `_pdf`, `_gerber` and `_static` are branches no current entry reaches. In its `setup` (after the `n-photo` block at `:186`):

```ruby
      # STAGE 4, S4-5: THREE MORE FILE PAGES, because eight viewer branches that used to be inline
      # in files/show.html.erb are now eight TEMPLATES — and the coverage assertion below counts
      # templates, not branches. `n-photo` already reaches files/viewers/_image and `n-pcb-0`
      # already exists for _gerber; these two are the ones with no node behind them. The `.bin` is
      # in no ROLE_BY_EXT entry and no renderer Registry, so its page takes _static's `else` arm —
      # VERIFY that with `FilesController.new.send(:preview_kind, "telemetry.bin") == :other`
      # before trusting it, and pick another extension if a later slice claims this one.
      file!("n-pdf", "manual.pdf", parent_node_id: folder.node_id)
      file!("n-other", "telemetry.bin", parent_node_id: folder.node_id)
```
and in the `pages` map, beside the five existing `"file detail (…)"` entries at `:310-314`:
```ruby
        "file detail (image)" => file_path("n-photo"),
        "file detail (pdf)" => file_path("n-pdf"),
        "file detail (gerber)" => file_path("n-pcb-0"),
        "file detail (other)" => file_path("n-other"),
```

- [ ] **Step 10: run, expect PASS.** `bin/rails test test/integration/web/template_hygiene_test.rb test/architecture_invariants_test.rb`. If the coverage assertion still names a `files/viewers/*` template, the fixture did not reach that branch — fix the fixture, never the assertion.

- [ ] **Step 11: mutation checks.** Run each, report both outputs, restore with `git checkout -- <file>` (and clear `tmp/cache/bootsnap*` after an equal-length restore).
  1. In `_model3d.html.erb` change `data-modelviewer-url-value="<%= named_url %>"` to `"<%= download_url %>"` → `files_flow_test.rb` **"an STL detail page renders the 3D viewer button-gated (lazy), not auto-loading"** FAILS on the `data-modelviewer-url-value` selector.
  2. In `show.html.erb`'s `:gerber` call drop `single: @gerber_single` → `gerber_preview_test.rb` ERRORS with `ActionView::Template::Error … missing local: single` on the first Gerber test. (This is the check that strict locals actually took effect — if it renders instead, the magic comment is not on line 1.)
  3. In `FilePreview#preview_kind` move `return :measure if MEASURABLE_EXTS.include?(ext)` below the `:image` branch → `lbrn_geometry_test.rb` **"an svg page posters the file itself, not a rendered thumbnail"** FAILS (an `.svg` takes `:image`).
  4. In `files_controller.rb` replace `KICANVAS_EXTS = FilePreview::KICANVAS_EXTS` with `KICANVAS_EXTS = %w[kicad_sch kicad_pcb].freeze` → the new identity test FAILS on `assert_same` while every other test stays green — which is the whole point of asserting identity.
  5. In `architecture_invariants_test.rb` revert the glob to the two original directories, and put `<%= current_user.email %>` in `_measure.html.erb` → the Public-namespace test stays **GREEN** (the gap Amendment 7 closes). Restore the glob, keep the mutation → it goes **RED** naming `app/views/files/viewers/_measure.html.erb`. Restore both. Report all four outputs from this one.

- [ ] **Step 12: commit.**

```bash
git add app/controllers/concerns/file_preview.rb app/controllers/files_controller.rb \
  app/views/files/viewers app/views/files/show.html.erb app/views/files/_measure.html.erb \
  test/architecture_invariants_test.rb test/integration/web/template_hygiene_test.rb
git commit -m "The file page's viewers become eight shared partials and one concern, so a second page can render them"
```

---

### Task B: the public file page

**Files:**
- Modify: `config/routes.rb`, `app/controllers/public/files_controller.rb`, `app/services/maker/public_project.rb`
- Create: `app/views/public/files/view.html.erb`, `test/integration/web/public_file_view_test.rb`
- Test: `test/integration/web/page_query_budget_test.rb`, `test/integration/web/template_hygiene_test.rb`

- [ ] **Step 1: the failing test.** Create `test/integration/web/public_file_view_test.rb`:

```ruby
require "test_helper"
require "support/public_fixture"

module Web
  # A VISITOR'S FILE PAGE (stage 4, S4-5; spec §2 D5 and §5's S4-5 row; stories 5.5, 5.7). The same
  # eight viewer partials the maker's own page renders (app/views/files/viewers/), pointed at public
  # URLs and permitted by the SAME object the page and the byte route ask, Maker::PublicProject.
  #
  # ITS OWN NODES, NOT `seed_public_project!`'S. Four suites assert about that fixture's contents —
  # public_bundle_test.rb pins the bundle's whole file list — so a .lbrn2, a .gtl and a .pdf added
  # there would be a change to four other suites for this one's convenience.
  class PublicFileViewTest < ActionDispatch::IntegrationTest
    include PublicFixture
    # `assert_no_enqueued_jobs` needs this EXPLICITLY — it is not on ActiveSupport::TestCase here
    # (test/integration/web/maker_page_thumbnails_test.rb:17 and s3_write_test.rb:25 both include it).
    include ActiveJob::TestHelper

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user)
      @project = @f[:project]
      @laser = make_file!(@user, "sign.lbrn2", @f[:folder], body: "<LightBurnProject/>")
      @gtl   = make_file!(@user, "driver.gtl", @f[:models], body: "%FSLAX46Y46*%\nM02*\n")
      @doc   = make_file!(@user, "manual.pdf", @f[:folder], body: "%PDF-1.4\n")
    end

    teardown { FileLayer.reset! }

    def view_path_for(node_id, **opts) = public_file_view_path("ada", @project.slug, node_id, **opts)

    test "a permitted model file gets the 3D viewer, pointed at the PUBLIC named byte route" do
      get view_path_for(@f[:base].node_id)

      assert_response :success
      assert_select ".model-viewer[data-controller=?]", "modelviewer"
      assert_select "[data-modelviewer-url-value=?]",
                    public_file_path("ada", @project.slug, @f[:base].node_id, filename: "base.stl")
      assert_select "[data-modelviewer-lazy-value=?]", "true"
      # NOT the private routes, anywhere on the page — the seam a public template must never cross.
      assert_select "a[href^='/files/']", count: 0
      assert_select "[data-modelviewer-url-value^='/files/']", count: 0
    end

    test "an image renders inline, a PDF is framed, a KiCad file mounts KiCanvas on the named URL" do
      get view_path_for(@f[:pic].node_id)
      assert_select "img.preview-image[src=?]", public_file_path("ada", @project.slug, @f[:pic].node_id)

      get view_path_for(@doc.node_id)
      assert_select "iframe.preview-pdf[src=?]", public_file_path("ada", @project.slug, @doc.node_id)

      get view_path_for(@f[:kicad].node_id)
      assert_select "[data-kicanvas-url-value=?]",
                    public_file_path("ada", @project.slug, @f[:kicad].node_id, filename: "driver.kicad_sch")
    end

    test "a Gerber layer renders the board viewer and a text file is READ-ONLY codeview" do
      get view_path_for(@gtl.node_id)
      assert_select ".gerber-viewer[data-controller=?]", "gerber"
      assert_select "[data-gerber-single-value=?]", "true"

      get view_path_for(@f[:readme].node_id)
      assert_select "[data-controller=?]", "codeview"
      assert_select "[data-controller=?]", "editor", 0, "a visitor must never get the editor mount"
      assert_select "form", 0, "a visitor's file page carries no form at all"
    end

    test "the Measure view ships whole: the launch, the paper picker, Print and Download SVG" do
      get view_path_for(@laser.node_id)

      assert_select ".measure-view[data-measure-url-value=?]",
                    public_file_geometry_path("ada", @project.slug, @laser.node_id)
      assert_select "[data-action=?]", "measure#load"
      assert_select "[data-action=?]", "measure#print"
      assert_select "[data-action=?]", "measure#downloadSvg"
    end

    test "the page carries the project breadcrumb, the author and a Download, and no notes panel" do
      get view_path_for(@f[:base].node_id)

      assert_select "nav.breadcrumb a[href=?]", public_project_path("ada", @project.slug)
      assert_select "nav.breadcrumb a[href=?]", public_user_path("ada")
      assert_select "a[href=?]", public_file_path("ada", @project.slug, @f[:base].node_id, download: 1)
      assert_select "section.notes-panel", count: 0
      assert_select "section.history-panel", count: 0
    end

    # THE PERMISSION IS `permits?`'S, NOT A SECOND ONE. Same matrix public_file_test.rb pins for the
    # bytes: if the view page could reach a node the byte route refuses, the page and the route
    # would disagree — which is the one thing Maker::PublicProject exists to prevent.
    test "a sibling of the folder, a dot-file, a directory and another maker's file are all 404" do
      [ @f[:outsider].node_id, @f[:dotfile].node_id, @f[:models].node_id, "no-such-node" ].each do |id|
        get view_path_for(id)
        assert_response :not_found, "#{id} must not have a public page"
      end
    end

    test "a private project's file page is a 404 and an unlisted one needs its token" do
      @project.update!(visibility: "private")
      get view_path_for(@f[:base].node_id)
      assert_response :not_found

      @project.update!(visibility: "unlisted")
      get view_path_for(@f[:base].node_id)
      assert_response :not_found

      get view_path_for(@f[:base].node_id, k: @project.reload.unlisted_token)
      assert_response :success
      # EVERY LINK CARRIES THE TOKEN, or the page links to its own 404s.
      assert_select "a[href*=?]", "k=#{@project.unlisted_token}"
    end

    test "the page render enqueues geometry once; the poll endpoint never writes" do
      assert_difference -> { @user.maker_previews.where(kind: "geometry").count }, 1 do
        get view_path_for(@laser.node_id)
      end
      # IDEMPOTENT: the row it just created is what makes the second render a no-op.
      assert_no_difference -> { @user.maker_previews.where(kind: "geometry").count } do
        get view_path_for(@laser.node_id)
      end

      assert_no_difference -> { @user.maker_previews.where(kind: "geometry").count } do
        assert_no_enqueued_jobs only: Maker::GeneratePreviewJob do
          get public_file_geometry_path("ada", @project.slug, @laser.node_id)
        end
      end
      assert_response :success
      assert_includes %w[pending processing ready failed unsupported], response.parsed_body["status"]
    end

    test "the geometry endpoint refuses a node the project does not permit, as JSON not a redirect" do
      get public_file_geometry_path("ada", @project.slug, @f[:outsider].node_id)
      assert_response :not_found
      assert_no_match(/<html/i, response.body, "a JSON poller must never be handed a page")
    end

    # ON s3 THE VIEWERS' FETCH LEAVES THE ORIGIN AND ONLY connect-src LETS THE BROWSER READ IT
    # (files-preview.md:410-422). No system test on the share leg can see this, and the existing CSP
    # suite only ever drives a SIGNED-IN page — so a public page losing the policy would be silent
    # on every leg. Branches on the CAPABILITY, exactly as content_security_policy_test.rb does.
    test "a public file page carries the same connect-src the private one does" do
      get view_path_for(@f[:base].node_id)
      sources = response.headers["Content-Security-Policy-Report-Only"][/connect-src ([^;]+)/, 1]
      port = FileLayer.current

      if port.capabilities.presignable?
        assert_equal "'self' #{port.presigned_origin}", sources
      else
        assert_equal "'self'", sources
      end
    end
  end
end
```

*(`use_fresh_share_library!` installs a Share adapter for this test on every leg, so the `presignable?` arm is the share arm here — it is written branching anyway because the same file runs under all three `LIBRARY_BACKEND` values and a future fixture may not pin share.)*

- [ ] **Step 2: run it, expect FAIL.** `bin/rails test test/integration/web/public_file_view_test.rb` → `NameError: undefined local variable or method 'public_file_view_path'`.

- [ ] **Step 3: the routes.** In `config/routes.rb`, **directly above** the existing `files#show` line (`:221`):

```ruby
    # STAGE 4, S4-5: THE VISITOR'S FILE PAGE AND ITS GEOMETRY POLL. BOTH MUST BE DECLARED ABOVE THE
    # BYTE ROUTE BELOW AND THE ORDER IS THE WHOLE GUARD: `files/:id(/*filename)` matches
    # `/files/abc/view` with `filename: "view"`, and `:filename` is decorative to the server (#show
    # resolves the node from :id alone), so declared the other way round this URL would serve THE
    # BYTES with a 200 and nothing anywhere to say so. Pinned by assert_recognizes in
    # public_file_view_test.rb.
    get "u/:handle/:slug/files/:id/view",     to: "files#view",     as: :file_view, constraints: { handle: /[a-z0-9][a-z0-9-]*/i }
    # The Measure view's coordinate payload, REPORT-ONLY: unlike FilesController#geometry this never
    # enqueues, because a poll a stranger can issue must not be a write (§14h's own rule for a
    # `failed` row, and ThumbnailMap's required `backfill:` flag). #view enqueues on the RENDER.
    get "u/:handle/:slug/files/:id/geometry", to: "files#geometry", as: :file_geometry, constraints: { handle: /[a-z0-9][a-z0-9-]*/i }
```
Add to the test, in the "3D viewer" test or its own:
```ruby
      assert_recognizes({ controller: "public/files", action: "view", handle: "ada",
                          slug: @project.slug, id: @f[:base].node_id },
                        "/u/ada/#{@project.slug}/files/#{@f[:base].node_id}/view")
```

- [ ] **Step 4: `Maker::PublicProject` grows two methods.** Insert directly above `private` (`public_project.rb:337`):

```ruby
    # THE VIEW PAGE'S URL, beside #file_url_for's byte URL (stage 4, S4-5). Same link_params, same
    # reason: on an unlisted project the token IS the credential and a link without it is a 404.
    # SEPARATE FROM #file_url_for RATHER THAN A FLAG ON IT, because the two answer different
    # questions and one of them is load-bearing elsewhere — Maker::Readme resolves a README's `<a>`
    # AND its `<img src>` through #file_url_for, so a flag defaulting the wrong way would point
    # every inline README image at an HTML page.
    def view_url_for(node_id)
      Rails.application.routes.url_helpers.public_file_view_path(handle, project.slug, node_id,
                                                                 **link_params)
    end

    # A .gbrjob's layer list, resolved in the OWNER's library and filtered by THIS project's
    # permission (stage 4, S4-5). The sibling walk is FilePreview's, shared with the maker's own
    # page; what is public here is only the URL builder, which answers nil for a sibling the project
    # does not permit — so a job file sitting next to a layer that is somehow outside the folder
    # renders the board WITHOUT it rather than handing a visitor a URL the byte route would refuse.
    # `permits?` is the same call #deliverable! makes, which is what keeps the two from disagreeing.
    def layer_url_for(node)
      permits?(node) ? file_url_for(node.node_id, filename: node.name) : nil
    end
```

- [ ] **Step 5: the controller.** Rewrite `app/controllers/public/files_controller.rb`:

```ruby
module Public
  # GET /u/:handle/:slug/files/:id(/*filename) — the BYTES of one file a published project shows.
  # GET /u/:handle/:slug/files/:id/view        — the PAGE, with the same viewers the maker gets.
  # GET /u/:handle/:slug/files/:id/geometry    — the Measure payload's location, report-only.
  #
  # <the existing header comment, unchanged, plus:>
  #
  # THE PAGE AND THE BYTES ASK ONE OBJECT (stage 4, S4-5). `#view` permits through the same
  # `Maker::PublicProject#deliverable!` `#show` does — not a second check that agrees today — so a
  # page that renders is a page whose viewer's fetch will succeed, and a node with no page has no
  # bytes either.
  #
  # NO SESSION, NO CAPABILITY GATE, NO EDITING. The viewer partials take every URL as a strict local
  # (app/views/files/viewers/), which is what lets this controller hand them public routes without
  # any of them knowing which page they are on; `editable: false` is what keeps `codeview` and not
  # `editor` on a visitor's page.
  class FilesController < BaseController
    include FileDelivery
    include FilePreview

    def show
      pub = public_project!
      node = pub.deliverable!(params[:id])
      deliver_file(pub.owner, node, download: params[:download].present?)
    end

    def view
      @pub = public_project!
      @node = @pub.deliverable!(params[:id])
      owner = @pub.owner
      @info = FileLayer.current.stat(owner, node_id: @node.node_id)
      @kind = preview_kind(@node.name)
      # ONE MAP FOR ONE NODE, not the project page's whole listing: `Maker::PublicProject#thumbs`
      # covers `listing.node_ids + page_nodes.keys`, and loading `page_nodes` here would pull the
      # build log, the BOM and every release onto a page that shows one file. `.for` backfills, which
      # is what makes a poster appear on a file nobody has opened before — the same write-on-GET the
      # public project page already does.
      @thumbnail = Maker::Previews::ThumbnailMap.for(owner, [ @node.node_id ]).thumb(@node.node_id)
      # A ZIP IS A BOARD WHEN ITS CONTENTS SAY SO, and a 3MF's colours/unit come from its manifest —
      # both are ONE bounded port read in the OWNER's name, judged on the catalog's `size` column
      # BEFORE any read and cached by content token, nil included. That bound is what makes them safe
      # on a route a stranger can issue.
      @gerber_archive = Maker::GerberArchive.archive?(@node.name) &&
                        Maker::GerberArchive.for(user: owner, node: @node)
      @kind = :gerber if @gerber_archive
      @viewer_manifest = Maker::ThreeMfManifest.for(user: owner, node: @node)
      @gerber_layers =
        if @gerber_archive
          [ helpers.gerber_archive_entry(name: @node.name,
                                         url: @pub.file_url_for(@node.node_id, filename: @node.name),
                                         members: @gerber_archive.stacked) ]
        elsif @kind == :gerber
          gerber_layers_for(user: owner, node: @node, url: ->(n) { @pub.layer_url_for(n) })
        end
      @gerber_single = @kind == :gerber && !gerber_job?(@node.name) && !@gerber_archive
      enqueue_geometry(owner) if @kind == :measure
    end

    # THE POLL, AND IT NEVER WRITES. FilesController#geometry enqueues when it finds no current row,
    # which is right for a door only the file's owner can open and wrong for one anybody can: a
    # `failed` row is re-enqueued by `Enqueue.call` on EVERY call (§14h), so a stranger reloading a
    # broken file would enqueue a doomed render per poll. The enqueue lives on the page render above
    # instead, guarded by `current_preview` so it fires once per (content, renderer build) — the same
    # split `Maker::Previews::ThumbnailMap`'s required `backfill:` flag draws between `#index`
    # (self-heals) and `#thumbnails` (polled every 2 s, must not write).
    #
    # `head :not_found` RATHER THAN THE PAGE'S 404, and rescued LOCALLY for FilesController#geometry's
    # reason: a JSON poller handed an HTML body reads neither a status key nor a 404.
    def geometry
      pub = public_project!
      node = pub.deliverable!(params[:id])
      token = FileLayer.current.stat(pub.owner, node_id: node.node_id)&.content_token
      return render json: { status: "pending" } if token.nil?

      preview = Maker::Previews::Enqueue.current_preview(user: pub.owner, node_id: node.node_id,
                                                         name: node.name, version_id: token,
                                                         kind: "geometry")
      # NO ROW YET IS `pending`, TRUTHFULLY: the page render that sent this poller here enqueued one.
      return render json: { status: "pending" } if preview.nil?

      case preview.status
      when "ready"
        render json: { status: "ready", url: (url_for(preview.asset) if preview.asset.attached?) }
      when "failed", "unsupported"
        render json: { status: preview.status, error: preview.error }
      else
        render json: { status: "pending" }
      end
    rescue ActiveRecord::RecordNotFound
      head :not_found
    end

    private

    # ONE JOB PER (node, content token, renderer build), and the `current_preview` guard is what
    # makes that true rather than "one job per page view": `Enqueue.call` resets a `failed` row to
    # pending and re-enqueues whenever it is called. `FilesController#current_thumbnail` is this
    # method's shape, with kind "thumbnail".
    def enqueue_geometry(owner)
      token = @info&.content_token
      return if token.blank?
      return if Maker::Previews::Enqueue.current_preview(user: owner, node_id: @node.node_id,
                                                         name: @node.name, version_id: token,
                                                         kind: "geometry")

      Maker::Previews::Enqueue.call(user: owner, node_id: @node.node_id, name: @node.name,
                                    version_id: token, kind: "geometry")
    rescue FileLayer::NotFound, FileLayer::FetchError
      nil
    end
  end
end
```
`Public::BaseController` has no `rescue_from ActiveRecord::RecordNotFound`, so `#view`'s refusal is Rails' own 404 — which is what `public_file_test.rb` already relies on for the byte route.

- [ ] **Step 6: the page.** Create `app/views/public/files/view.html.erb`:

```erb
<%#
  ONE FILE OF A PUBLISHED PROJECT, READ-ONLY, FOR ANYONE (stage 4, S4-5; spec §2 D5, story 5.5).

  THE SAME EIGHT PARTIALS THE MAKER'S OWN PAGE RENDERS (app/views/files/viewers/), which is D5 in
  one sentence: the viewers were never session-aware, only their URLs were. Every local below is a
  PUBLIC url off `@pub`, so nothing here can reach /files/:id — and the seam guard in
  test/architecture_invariants_test.rb scans those partials for exactly that.

  NOTHING A VISITOR CANNOT DO: no notes panel, no attach control, no history panel, no editor mount,
  no Delete. `editable: false` is what keeps the text branch on `codeview`, which sets both
  EditorState.readOnly and EditorView.editable.

  MEASURE SHIPS WHOLE. Print-to-scale and Download SVG are client-side work over a payload the
  visitor has already fetched, so withholding them would cost a visitor the one thing story 5.5 asks
  for and save nothing. There has never been a note control in that bar to drop.
%>
<% content_for :title, "#{@node.name} — #{@pub.project.name} — @#{@pub.handle}" %>
<% content_for :container_class, "public-main" %>

<%# A REAL BREADCRUMB IN THE PAGE, NOT `content_for :crumbs` — the layout renders layouts/topbar
    (which consumes :crumbs) only on the signed-in branch. public/projects/show.html.erb's own rule. %>
<nav class="breadcrumb" aria-label="File path">
  <%= link_to "@#{@pub.handle}", public_user_path(@pub.handle) %>
  <span class="sep" aria-hidden="true">/</span>
  <%= link_to @pub.project.name, public_project_path(@pub.handle, @pub.project.slug, **@pub.link_params) %>
  <span class="sep" aria-hidden="true">/</span>
  <span aria-current="page"><%= @node.name %></span>
</nav>

<div class="page-head public-head">
  <div class="page-title">
    <h1><%= @node.name %></h1>
    <% ext = File.extname(@node.name).delete(".").upcase %>
    <% if ext.present? %><span class="badge file-badge"><%= ext %></span><% end %>
  </div>
  <div class="page-actions">
    <%= link_to "Download", @pub.file_url_for(@node.node_id, download: true), class: "btn" %>
  </div>
</div>

<dl class="meta">
  <dt>Name</dt><dd><%= @node.name %></dd>
  <dt>Size</dt><dd><%= @info&.content_token ? number_to_human_size(@info.size) : "—" %></dd>
  <dt>Type</dt><dd class="mono"><%= Marcel::MimeType.for(name: @node.name) %></dd>
  <%# FileInfo#mtime is unix NANOSECONDS — reading it as seconds is the overflow bug this codebase
      has shipped twice. No "Current version" row: `capabilities.versioned?` is a deployment fact a
      visitor has no use for, and this page carries no owner-facing metadata at all. %>
  <dt>Modified</dt>
  <dd><%= @info&.mtime ? Time.at(@info.mtime / 1_000_000_000).strftime("%Y-%m-%d %H:%M") : "—" %></dd>
</dl>

<div class="preview-row">
  <div class="preview">
  <% blob = @pub.file_url_for(@node.node_id) %>
  <% named = @pub.file_url_for(@node.node_id, filename: @node.name) %>
  <% download = @pub.file_url_for(@node.node_id, download: true) %>
  <% if @info&.content_token.nil? %>
    <p class="muted">No content yet.</p>
  <% elsif @kind == :image %>
    <%= render "files/viewers/image", name: @node.name, blob_url: blob %>
  <% elsif @kind == :pdf %>
    <%= render "files/viewers/pdf", name: @node.name, blob_url: blob %>
  <% elsif @kind == :kicanvas %>
    <%= render "files/viewers/kicanvas", named_url: named, controls: "full" %>
  <% elsif @kind == :gerber %>
    <%= render "files/viewers/gerber", layers: @gerber_layers, single: @gerber_single,
               thumbnail: @thumbnail, name: @node.name, download_url: download %>
  <% elsif @kind == :text %>
    <%= render "files/viewers/code", blob_url: blob, editable: false, save_url: nil, base_token: nil,
               ext: File.extname(@node.name).downcase.delete(".") %>
  <% elsif @kind == :model3d %>
    <%= render "files/viewers/model3d", name: @node.name, named_url: named,
               format: File.extname(@node.name).downcase.delete("."),
               colors: (@viewer_manifest&.colors || []),
               unit_factor: (@viewer_manifest&.unit_factor || 1.0),
               thumbnail: @thumbnail, download_url: download %>
  <% elsif @kind == :measure %>
    <%= render "files/viewers/measure", name: @node.name, blob_url: blob, thumbnail: @thumbnail,
               geometry_url: public_file_geometry_path(@pub.handle, @pub.project.slug,
                                                       @node.node_id, **@pub.link_params),
               download_url: download %>
  <% else %>
    <%= render "files/viewers/static", kind: @kind, thumbnail: @thumbnail, name: @node.name,
               download_url: download %>
  <% end %>
  </div>
  <%# NO RECIPE PANEL. files/_lbrn_settings and _mage_settings render a laser's speed/power table and
      a mill's operations — the maker's own settings, not documentation of the design. Out of D5's
      "the existing viewers as they are"; add one only when a story asks. %>
</div>
```

- [ ] **Step 7: the public project page links here.** In `app/views/public/projects/_files.html.erb` change the name cell (`:43`) and keep Download unchanged:
```erb
              <td class="col-name"><%= link_to row.node.name, pub.view_url_for(row.node_id) %></td>
```
and in `_photos.html.erb` change the cell's link target (`:16`):
```erb
        <%= link_to pub.view_url_for(row.node_id), class: "photo-cell file-cell",
                    title: row.node.name do %>
```
Add one sentence to each partial's header: the name now opens the file's own page (S4-5) and Download still fetches the bytes, so a visitor gets the viewer by clicking the name and the file by clicking Download. **`_schematics.html.erb` is unchanged** — its own comment says the list links `download: true` *"and there is no private file page to send them to instead"*; that sentence is now false, so Task D corrects it in `files-preview.md` and this partial's own header keeps its `download: true` links (a `.kicad_sch` list beside an inline KiCanvas embed already shows the board; sending the list to a second KiCanvas page is a change of behaviour D5 does not ask for). Update `public_project_test.rb:165-166` (the two `.photos-panel a[href=?]` assertions) to `public_file_view_path`, and add one assertion that the Download column still names `public_file_path(..., download: 1)`.

- [ ] **Step 8: run, expect PASS.** `bin/rails test test/integration/web/public_file_view_test.rb test/integration/web/public_file_test.rb test/integration/web/public_project_test.rb test/integration/web/public_bundle_test.rb`.

- [ ] **Step 9: the query budget.** Append to `page_query_budget_test.rb`, after the `public projects#show` test:

```ruby
    # A VISITOR'S FILE PAGE COSTS THE SAME ON A BIG PROJECT AS ON A SMALL ONE (stage 4, S4-5). What
    # could grow it: `Maker::PublicProject` builds a LibraryTree and a ProjectFolderListing in its
    # constructor, so a folder with more files must not cost more queries; a .gbrjob's sibling walk
    # is ONE bounded query; and `page_nodes` — the build log, the BOM, every release — must never be
    # loaded at all, which is exactly what a `permits?` answered by ancestry avoids (its own comment
    # says the file route never reaches `visible_page_ids`; this page must not either).
    test "public files#view does not grow with the project's files, entries or releases" do
      delete destroy_user_session_path
      @user.update!(handle: "viewbudget")
      project = @user.maker_projects.create!(name: "Viewed", status: "active", visibility: "public")
      folder = project_folder_rows!(@user, project)
      subject = node!("view-subject", "hero.stl")
      subject.update!(parent_node_id: folder.node_id)
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          @user.nodes.create!(node_id: id, name: "#{id}.stl", kind: "file", parent_node_id: folder.node_id,
                              size: 1, mtime: 1_700_000_000_000_000_000,
                              content_hash: "h-#{id}", current_version_id: "v-#{id}")
          entry = project.build_log_entries.create!(user: @user, body: "e#{id}", logged_at: Time.current)
          entry.file_attachments.create!(user: @user, node_id: id, role: "image", position: 0)
          release = project.releases.create!(user: @user, version: "v#{id}", published_at: Time.current)
          release.files.create!(user: @user, node_id: id, name: "#{id}.stl", path: "#{id}.stl",
                                content_token: "h-#{id}", size: 1)
        end
      end
      assert_constant_queries(public_file_view_path(@user.handle, project.slug, "view-subject"),
                              -> { add.call("vs", SMALL) },
                              -> { add.call("vl", LARGE - SMALL) },
                              "public files#view")
    end
```

- [ ] **Step 10: the template sweep reaches both public file pages.** In `template_hygiene_test.rb`'s `pages` map, beside the public entries at `:351-364`:
```ruby
        # STAGE 4, S4-5: the visitor's file page, and the unlisted branch of it — the token rides
        # every URL the page builds, which is the half a public-project-only sweep cannot see.
        "public file (3d)" => public_file_view_path(@user.handle, @project.slug, "n-stl"),
        "public file (measure)" => public_file_view_path(@user.handle, @project.slug, "n-bak"),
```
`n-stl` and `n-bak` sit outside the project folder in that fixture, so they are permitted only if attached — and they are (`@project.file_attachments.create!` at `:116-117`), which is the attachment arm of `permits?`. Verify by running the sweep, not by reading.

- [ ] **Step 11: run, expect PASS.** `bin/rails test test/integration/web/page_query_budget_test.rb test/integration/web/template_hygiene_test.rb test/integration/web/content_security_policy_test.rb`.

- [ ] **Step 12: mutation checks.** Report both outputs for each.
  1. Move the two new route lines BELOW `files#show` in `config/routes.rb` → the new suite's `assert_recognizes` FAILS, and every `assert_select` in it fails because the response is a byte stream. (This is Amendment 6's trap, made visible.)
  2. In `Public::FilesController#view` replace `@pub.deliverable!(params[:id])` with `@pub.owner.nodes.present.find_by!(node_id: params[:id])` → **"a sibling of the folder, a dot-file, a directory and another maker's file are all 404"** FAILS on `@f[:outsider]` and `@f[:dotfile]`.
  3. In `view.html.erb`'s `:model3d` call pass `named_url: blob` instead of `named` → **"a permitted model file gets the 3D viewer, pointed at the PUBLIC named byte route"** FAILS on `data-modelviewer-url-value`.
  4. In `#geometry` add `Maker::Previews::Enqueue.call(...)` in the `preview.nil?` branch → **"the page render enqueues geometry once; the poll endpoint never writes"** FAILS on `assert_no_difference`.
  5. In `#view` drop the `current_preview` guard from `enqueue_geometry` → the same test FAILS on the second `assert_no_difference` (the idempotence half).
  6. In `Maker::PublicProject#layer_url_for` return `file_url_for(...)` unconditionally → add one case to the suite first (a `.gbrjob` whose named sibling sits outside the folder) and confirm it FAILS; if writing that fixture proves awkward, say so and mutation-check `permits?`'s presence by asserting `layer_url_for(@f[:outsider])` is nil in a unit test on `test/services/maker/public_project_test.rb` instead.

- [ ] **Step 13: commit.**

```bash
git add config/routes.rb app/controllers/public/files_controller.rb app/views/public/files \
  app/services/maker/public_project.rb app/views/public/projects/_files.html.erb \
  app/views/public/projects/_photos.html.erb test/integration/web/public_file_view_test.rb \
  test/integration/web/public_project_test.rb test/integration/web/page_query_budget_test.rb \
  test/integration/web/template_hygiene_test.rb
git commit -m "A visitor gets the file page: the same viewers, public URLs, and a geometry poll that never writes"
```

---

### Task C: covers, the hero, and a header a visitor can navigate from

**Files:**
- Modify: `app/views/public/_project_card.html.erb`, `app/controllers/public/explore_controller.rb`, `app/controllers/public/users_controller.rb`, `app/services/maker/public_project.rb`, `app/views/public/projects/show.html.erb`, `app/views/layouts/application.html.erb`, `app/helpers/shell_helper.rb`, `app/assets/stylesheets/shell.css`, `app/assets/stylesheets/pages/public.css`
- Create: `app/views/layouts/_public_header.html.erb`
- Test: `test/integration/web/public_explore_test.rb`, `public_project_test.rb`, `page_query_budget_test.rb`, `test/system/shell_test.rb`

- [ ] **Step 1: the failing tests.** `public_explore_test.rb` is **deliberately port-free** — its own header (`:13-14`) says *"neither list touches the port at all (no listing, no README, no thumbnail), so these run on the ambient backend on all three legs"* — and covers must not break that. Its additions therefore assert only what needs no bytes: the placeholder branch, the absence of the poll, and the header. Append:

```ruby
    # STAGE 4, S4-5. NO COVER FIXTURE HERE, AND THAT IS THIS SUITE'S OWN RULE, NOT AN OMISSION: a
    # ready cover needs real bytes behind it, which means use_fresh_share_library!, which is exactly
    # the share pin this file's header refuses. The READY branch is asserted in public_project_test.rb,
    # which already owns a share library. What belongs here is the branch that needs nothing — and
    # the absence of the poll, which no share-pinned test would notice.
    test "a public card carries a cover slot, with the placeholder when there is no cover and never a poll" do
      get public_explore_path

      assert_response :success
      assert_select ".project-card .card-cover", minimum: 1
      assert_select ".project-card .project-thumb-empty", minimum: 1
      # /files/thumbnails is session-authed, so a visitor's spinner has nothing that could ever
      # resolve it. The controller must not be on this page at all.
      assert_select "[data-controller=?]", "thumbs", 0
    end

    test "the anonymous header names the site and, on a maker's page, the maker" do
      get public_explore_path
      assert_select "header.public-header a[href=?]", public_explore_path
      assert_select "header.public-header p.public-intro"

      get public_user_path("ada")
      assert_select "header.public-header a[href=?]", public_user_path("ada")
      assert_select "header.public-header p.public-intro", 0
    end

    test "a signed-in visitor still gets the visitor's header and no rail" do
      sign_in_as(@ada)
      get public_explore_path
      assert_select "header.public-header", 1
      assert_select "aside.rail", 0
    end

    test "the sign-in page gets no public header" do
      get new_user_session_path
      assert_select "header.public-header", 0
    end
```
and to `public_project_test.rb` (share-pinned, so it can assert the ready branch):
```ruby
    # THE READY COVER, ON THE MAKER'S OWN PAGE. /u/:handle is SINGLE-OWNER, which is the whole reason
    # it gets covers and /explore does not: ThumbnailMap is per-user (a preview row belongs to its
    # owner, and the port is asked in the owner's name), so one map serves this page and a cross-user
    # list would need one per maker. Amendment 9.
    test "a maker's page shows each project's cover as a ready thumbnail" do
      preview = @user.maker_previews.create!(node_id: @f[:pic].node_id, kind: "thumbnail",
                                             status: "ready",
                                             version_id: FileLayer.current.stat(@user, node_id: @f[:pic].node_id).content_token)
      preview.asset.attach(io: StringIO.new(PublicFixture::PNG_BYTES), filename: "pic.png",
                           content_type: "image/png")
      @project.update_column(:cover_node_id, @f[:pic].node_id)

      get public_user_path("ada")

      assert_response :success
      assert_select ".project-card .card-cover img"
      assert_select "[data-controller=?]", "thumbs", 0
    end
```
(`renderer_revision` defaults to 1 and `Maker::Previews::Enqueue.current_preview?` compares it against `revision_for_name("pic.png", "thumbnail")` — if that is not 1 on this build, set it explicitly from `Maker::Previews::Enqueue.send(:revision_for_name, "pic.png", "thumbnail")` rather than hard-coding a number. Verify before writing the assertion; a silently non-current row renders the placeholder and this test would fail for the wrong reason.)

Also to `public_project_test.rb`:
```ruby
    test "the public project page leads with its cover, linking to the file's own page" do
      @project.update_column(:cover_node_id, @f[:pic].node_id)

      get path

      assert_select ".project-hero img[src=?]", public_file_path("ada", @project.slug, @f[:pic].node_id)
      assert_select ".project-hero a[href=?]", public_file_view_path("ada", @project.slug, @f[:pic].node_id)
    end

    test "a cover the project does not permit renders no hero at all" do
      @project.update_column(:cover_node_id, @f[:outsider].node_id)

      get path

      assert_select ".project-hero", 0, "an unpermitted cover must not become a public picture"
    end
```
Fill `@owner` in `public_explore_test.rb` from whatever that suite already names its handle-carrying user; read its `setup` rather than assuming.

- [ ] **Step 2: run, expect FAIL** on `.project-card .thumb` and `header.public-header`.

- [ ] **Step 3: the cover on a card.** `app/views/public/_project_card.html.erb` gains, as the first child of the `<article>`:

```erb
  <%#
    THE COVER (stage 4, S4-5; story 5.7). `thumb` is a Maker::Preview or nil — the private
    projects/_card's shape, minus the poll: /files/thumbnails is session-authed, so a visitor's
    spinner has nothing that could ever resolve it. A card with no cover node gets the same neutral
    placeholder the private card uses, never a forever-spinner.

    `thumb` IS ALLOWED TO BE nil AND /explore ALWAYS PASSES nil (Amendment 9). ThumbnailMap is
    per-user, so a cross-user list would cost two statements per distinct maker — measured by
    page_query_budget_test.rb, whose explore seed mints one owner per project because that is what
    /explore is. This is ONE condition (does this card have a ready cover thumbnail?) answered from
    whatever each caller actually holds, not two answers to one condition.

    Locals: project (Maker::Project, publicly listed), thumb (Maker::Preview or nil).
  %>
  <%= link_to public_project_path(project.user.handle, project.slug), class: "card-cover" do %>
    <% if thumb&.status == "ready" && thumb.asset.attached? %>
      <span class="thumb"><img src="<%= url_for(thumb.asset) %>" alt="" loading="lazy"></span>
    <% else %>
      <span class="thumb project-thumb-empty" aria-hidden="true">📦</span>
    <% end %>
  <% end %>
```
`explore/index.html.erb:35` becomes `render "public/project_card", project: project, thumb: nil` and `users/show.html.erb:19` becomes `render "public/project_card", project: project, thumb: @covers.thumb(project.cover_node_id)`. `ThumbnailMap#thumb(nil)` answers nil (`@previews[nil]`), so a coverless project needs no branch at the call site.

- [ ] **Step 4: only `Public::UsersController` resolves covers, and it is single-owner.** No new service, no `CoverMap` (see Amendment 9 and Open question 1 before reaching for one):
```ruby
    def show
      @owner = owner!
      # `:user` AND `:file_attachments` ARE BOTH LOAD-BEARING (stage 4, S4-5). The card renders
      # `project.user.handle` twice, and Maker::Project#cover_node_id falls back to
      # #derived_cover_node_id, which reads the attachments — without either eager load this page is
      # a query per card, which the new "public users#show" budget is what says so.
      @projects = @owner.maker_projects.publicly_listed.includes(:user, :tags, :file_attachments)
                        .order(updated_at: :desc).to_a
      # ONE ThumbnailMap FOR THE WHOLE PAGE, and it can BE one because this page has exactly one
      # owner. `.for` backfills, which is what starts the render for a project nobody has opened —
      # the public project page has done the same on an anonymous visit since S3-4. READY rows only
      # at the view: nothing here polls, because /files/thumbnails is session-authed.
      @covers = Maker::Previews::ThumbnailMap.for(@owner, @projects.filter_map(&:cover_node_id))
    end
```
`Public::ExploreController#index` is left alone except for its comment: add one line saying the card's cover slot is deliberately empty here, with the per-maker cost as the reason and Amendment 9 / Open question 1 as the pointer. **Do not add `:file_attachments` to its `includes`** — nothing on that page reads them now, and an eager load nothing uses is a bigger query for no benefit.

- [ ] **Step 5: the hero on the public project page.** `Maker::PublicProject` gains, directly after `#photo_rows`:
```ruby
    # THE COVER, PERMITTED (stage 4, S4-5; story 5.7). `Maker::Project#cover_node_id` derives one
    # from the attachments when none is chosen, and a CHOSEN cover is a raw column nothing validates
    # (ProjectsController#project_params) — so it can name a node outside the folder, a tombstone, or
    # a file this project has no claim on at all. `permits?` is the one answer to "is this file
    # public" and it answers here too: an unpermitted cover renders NOTHING rather than becoming the
    # page's largest picture. nil is a real answer, hence `defined?` and not `||=`.
    def cover_node
      return @cover_node if defined?(@cover_node)

      id = project.cover_node_id
      node = id && owner.nodes.present.find_by(node_id: id)
      @cover_node = (node if node && permits?(node))
    end
```
and `public/projects/show.html.erb` gains, directly above `<div class="project-panels">`:
```erb
<%# THE HERO (stage 4, S4-5): the same picture the private page has led with since S4-1, on the page
    a visitor sees. An image-role cover is the picture itself through the byte route; any other cover
    is its READY server thumbnail, with no poll (the poll endpoint is session-authed) and no
    placeholder box — a public page with no cover simply has no hero, exactly as the private one. %>
<% if (cover = @pub.cover_node) %>
  <div class="project-hero">
    <%= link_to @pub.view_url_for(cover.node_id) do %>
      <% if Maker::FileAttachment.role_for(cover.name) == "image" %>
        <%= image_tag @pub.file_url_for(cover.node_id), class: "project-hero-img", alt: cover.name %>
      <% else %>
        <% thumb = @pub.thumbs.thumb(cover.node_id) %>
        <% if thumb&.status == "ready" && thumb.asset.attached? %>
          <%= image_tag url_for(thumb.asset), class: "project-hero-img", alt: "Preview of #{cover.name}" %>
        <% end %>
      <% end %>
    <% end %>
    <span class="project-hero-name mono muted"><%= cover.name %></span>
  </div>
<% end %>
```
`@pub.thumbs` is already memoised for the page, so the hero costs no query of its own; a cover outside the listing is not in that map and falls through to no picture, which is the honest answer on a page that cannot poll.

- [ ] **Step 6: the header.** `app/helpers/shell_helper.rb` — one definition, and `shell_signed_in?` reads it so the two cannot disagree:
```ruby
  # IS THIS A PUBLIC SURFACE? `respond_to?` on both halves because a public controller stands on
  # ActionController::Base and Devise's own pages have neither helper. Extracted from
  # #shell_signed_in? (stage 4, S4-5) so the layout can ask it directly for the visitor's header
  # without a second copy of the double-`respond_to?` dance — and so the ORDER argument below stays
  # in one place.
  def public_shell? = respond_to?(:public_surface?) && public_surface?

  def shell_signed_in?
    # THE PUBLIC CHECK COMES FIRST, AND THE ORDER IS LOAD-BEARING <existing comment, unchanged>
    return false if public_shell?

    respond_to?(:user_signed_in?) && user_signed_in?
  end
```
Create `app/views/layouts/_public_header.html.erb`:
```erb
<%#
  THE VISITOR'S HEADER (stage 4, S4-5; story 5.7). The anonymous branch of the layout carried no
  chrome at all: a visitor who landed on a project page had nothing naming the site and no way to
  the maker's other work but the breadcrumb.

  RENDERED ONLY ON A PUBLIC SURFACE, never on the auth card. Devise's pages share the anonymous
  branch and are a different surface — a sign-in form under an Explore link reads as a site nav on a
  page that has none. `public_shell?` is the same question `shell_signed_in?` asks first.

  NO SESSION, THEREFORE NO ACCOUNT LINK. This partial renders identically for a signed-in owner
  previewing their own page (Public::BaseController#public_surface?), which is the honest preview,
  and adding "signed in as…" here would be the session read §14d forbids on this surface.

  `.brand` IS THE RAIL'S OWN MARKUP, reused rather than restyled — shell.css defines it once.
%>
<header class="public-header">
  <%= link_to public_explore_path, class: "brand", "aria-label": "Tinkerex — explore" do %>
    <span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Tinkerex</span>
  <% end %>
  <%# THE AUTHOR, when the page has one. @owner on /u/:handle, @pub on a project or file page —
      both are set by the controller that renders them, and `defined?` is what keeps this partial
      usable on /explore, which has neither. %>
  <% author = (@pub&.handle if defined?(@pub)) || (@owner&.handle if defined?(@owner)) %>
  <% if author %>
    <%= link_to "@#{author}", public_user_path(author), class: "public-author" %>
  <% else %>
    <p class="public-intro muted">Projects makers have published — the files, the photos and the build log.</p>
  <% end %>
</header>
```
and `app/views/layouts/application.html.erb`'s anonymous branch (`:45-53`) gains one line above the flash:
```erb
    <% else %>
      <%= render "layouts/public_header" if public_shell? %>
      <%= render "layouts/flash" %>
```

- [ ] **Step 7: the CSS.** `.public-header` is anonymous-shell chrome, so it goes in **`app/assets/stylesheets/shell.css`** inside `@layer shell`, beside `.brand` — `pages/public.css` stays about page content, and a `pages`-layer rule would outrank `shell` and start a cascade fight. It must not redeclare any `COMPONENT_SELECTORS` entry (`test/css_hygiene_test.rb:32-36`).
```css
  /* --- The visitor's header (stage 4, S4-5). The anonymous branch's only chrome: the wordmark and,
     on a maker's page, the maker. Not the rail — a visitor has no library to navigate. --- */
  .public-header { display: flex; flex-wrap: wrap; align-items: center; gap: 12px;
                   max-width: 1360px; margin: 0 auto; padding: 10px 16px;
                   border-bottom: 1px solid var(--line); }
  .public-header .public-author { color: var(--fg-muted); font-size: 12px; }
  .public-header .public-intro { margin: 0; font-size: 12px; }
```
In `pages/public.css`, beside the existing `.public-photos` block, add the card cover and reuse S4-1's hero sizing (the `.project-hero*` rules live in `pages/projects.css` and are **not** loaded-conditional — every page links every sheet — so nothing needs duplicating; add only what the public card needs):
```css
  .project-card-grid .card-cover { display: block; }
  .project-card-grid .card-cover .thumb { width: 100%; height: 120px; }
  .project-card-grid .project-thumb-empty { display: flex; align-items: center; justify-content: center;
                                            font-size: 28px; }
```
Confirm `.project-thumb-empty` is not a `COMPONENT_SELECTORS` entry and is already defined in `pages/projects.css`; if it is, qualify rather than redeclare (`.project-card-grid .project-thumb-empty`), which is what the snippet above already does.

- [ ] **Step 8: run, expect PASS.** `bin/rails test test/integration/web/public_explore_test.rb test/integration/web/public_project_test.rb test/css_hygiene_test.rb test/integration/web/shell_layout_test.rb`.

- [ ] **Step 9: the budgets.** Two edits, and the first is the one that *measures* Amendment 9 rather than assuming it. In `page_query_budget_test.rb`'s `explore#index` seed (`:393-407`), give every project a cover:
```ruby
          owner.maker_projects.create!(name: "Lamp #{id}", description: "A lamp.", status: "active",
                                       visibility: "public", tag_list: "tag-#{id}")
                .file_attachments.create!(user: owner, node_id: "#{id}-cover", role: "image", position: 0)
          # A COVER PER PROJECT, ON A SEED THAT MINTS ONE OWNER PER PROJECT — which is what /explore
          # is. This is not decoration: it is what makes this test able to fail if the cards ever
          # start resolving covers here. Maker::Previews::ThumbnailMap is PER-USER (the row belongs
          # to its owner, the port is asked in the owner's name — §14a), so a cover map on a
          # cross-user list is two statements per distinct maker and this assertion goes red. S4-5
          # gave covers to /u/:handle for exactly that reason; see this plan's Amendment 9.
```
(the `node!` helper is `@user`-scoped — mint the cover node on `owner` directly with the same two content columns `node!` sets, or drop the node entirely: `cover_node_id` need not resolve for the query count to be the point.)

Then append a new case:
```ruby
    # /u/:handle GREW PER-CARD WORK IN S4-5 (a cover thumbnail and the maker's handle), so it earns a
    # budget of its own — it had none. `includes(:user, :file_attachments)` is what makes it constant;
    # dropping either is a query per card, and the card renders `project.user.handle` twice.
    test "public users#show does not grow with the number of projects" do
      delete destroy_user_session_path
      @user.update!(handle: "cardbudget")
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          project = @user.maker_projects.create!(name: "P#{id}", visibility: "public", status: "active")
          node!("#{id}-cover", "#{id}.png")
          project.file_attachments.create!(user: @user, node_id: "#{id}-cover", role: "image", position: 0)
        end
      end
      assert_constant_queries(public_user_path("cardbudget"),
                              -> { add.call("us", SMALL) },
                              -> { add.call("ul", LARGE - SMALL) },
                              "public users#show")
    end
```

- [ ] **Step 10: the phone sweep.** In `test/system/shell_test.rb`'s public loop (`:337-341`), add the file page as a fourth entry:
```ruby
      { public_project_path(@user.handle, project.slug) => ".kicanvas-stage[data-kicanvas-state='ready']",
        public_file_view_path(@user.handle, project.slug, long.node_id) => ".preview-code",
        public_user_path(@user.handle) => "main.public-main .project-card-grid",
        public_explore_path => "main.public-main .project-card-grid" }.each do |path, marker|
        visit path
        assert_selector marker
        assert_selector "header.public-header"
        assert_no_selector "nav.tabbar"
        assert_no_selector "aside.rail"
        no_sideways_scroll.call(path)
      end
```
`long` is that suite's own long-named node; it must be **attached to the project or inside its folder** or the page 404s and `visit` will not say so — the loop's own comment records exactly that hazard. Read the fixture at `:104-175` and pick a node that is; if none is, attach `long` to the project in `setup` with a one-line comment saying why.

- [ ] **Step 11: run, expect PASS.** `bin/rails test test/integration/web/page_query_budget_test.rb` then `bin/rails test test/system/shell_test.rb`.

- [ ] **Step 12: mutation checks.** Report both outputs for each.
  1. Drop `:user, :file_attachments` from `UsersController#show` → the new **"public users#show does not grow with the number of projects"** FAILS with a larger count on the large seed. Run it once with only `:user` dropped and once with only `:file_attachments` dropped, and report both — either alone is a query per card, and a single combined mutation cannot tell you both halves carry weight.
  2. **The one that prices Amendment 9.** In `explore/index.html.erb` change `thumb: nil` to `thumb: Maker::Previews::ThumbnailMap.for(project.user, [ project.cover_node_id ]).thumb(project.cover_node_id)` (the naive per-card spelling) → **"explore#index does not grow with public projects or tags"** FAILS, and the delta between the small and large counts is the per-maker cost Open question 1 is asking about. **Report the two numbers** — they are the input to that decision, not just a red/green.
  3. In `Maker::PublicProject#cover_node` drop the `&& permits?(node)` → **"a cover the project does not permit renders no hero at all"** FAILS.
  4. In `layouts/application.html.erb` drop the `if public_shell?` guard → **"the sign-in page gets no public header"** FAILS.
  5. In `_project_card.html.erb` add `data-controller="thumbs"` to the cover cell → **"a public card carries a cover slot…"** FAILS on `assert_select "[data-controller=?]", "thumbs", 0`.
  6. In `public_project_test.rb`'s new ready-cover test, set the preview's `version_id` to `"stale"` → it FAILS on `.card-cover img`, which is what proves the map is enforcing currency rather than serving any row it finds (§14h's "a stale row was SERVED" bug).

- [ ] **Step 13: commit.**

```bash
git add app/views/public app/controllers/public app/services/maker/public_project.rb \
  app/views/layouts app/helpers/shell_helper.rb \
  app/assets/stylesheets/shell.css app/assets/stylesheets/pages/public.css \
  test/integration/web/public_explore_test.rb test/integration/web/public_project_test.rb \
  test/integration/web/page_query_budget_test.rb test/system/shell_test.rb
git commit -m "Public cards carry covers, the public project page leads with its hero, and a visitor gets a header"
```

---

### Task D: the document this slice falsifies

- [ ] **Step 1: `docs/invariants/files-preview.md`.** Three edits, each anchored on a heading rather than a line number (S4-2 is editing this file on another branch):
  - Under **`:model3d` is the browser's own viewer** (near the `named_blob_file_path` paragraph at `:335`): add that the rule now binds on **two** URL builders — `named_blob_file_path` privately and `Maker::PublicProject#file_url_for(id, filename:)` publicly — and that both templates reach it through one strict-locals partial (`app/views/files/viewers/_model3d.html.erb`, local `named_url:`), so there is one place the rule can be broken rather than two.
  - Under the `:gerber` section: correct the sentence in `app/views/public/projects/_schematics.html.erb`'s own header that says *"there is no private file page to send them to instead"* — there is a public one now — and record that a `.gbrjob`'s sibling list is filtered through `Maker::PublicProject#permits?` publicly, so a board can render **without** a layer the project does not permit rather than linking one the byte route would refuse.
  - Under **`/files/thumbnails` MUST answer for a node with no row**: add a paragraph that **no public surface polls** — the endpoint is session-authed — so a public poster is whatever is ready at render time, the render backfills (`ThumbnailMap.for`), and `files/viewers/_static`'s "Generating preview…" is a statement a reload resolves rather than a promise. Name the one asymmetry S4-5 introduced and why: `FilesController#geometry` enqueues and `Public::FilesController#geometry` does not, because the enqueue moved to the public page's render, guarded by `current_preview` so a `failed` row cannot be re-enqueued per poll.
- [ ] **Step 2: run** `bin/rails test test/docs_hygiene_test.rb` → PASS.
- [ ] **Step 3: commit.** `git commit -m "The preview invariants record the shared viewer partials and the public page's un-polled poster"`

---

### Task E: close-out

- [ ] **Step 1: re-tag the stories** in `docs/user-stories.md`, with the new evidence in the last column:
  - 5.5 → **`works`**: *"**S4-5:** a public file page (`/u/:handle/:slug/files/:id/view`) renders the same eight viewer partials the maker's own page does (`app/views/files/viewers/`) — 3D, Measure (read-only, print and SVG export kept), Gerber, KiCanvas, image, PDF and source — over the public byte route, permitted by `Maker::PublicProject#permits?`."*
  - 5.7 stays **`rough`** with new evidence: *"**S4-5:** the anonymous layout carries a header — the site name to `/explore`, the maker's handle on a project or file page (`layouts/_public_header`); `/u/:handle`'s cards show each project's cover as a ready thumbnail and the public project page leads with the same hero S4-1 gave the private one. Still rough: `/explore`'s cards carry the placeholder — `Maker::Previews::ThumbnailMap` is per-user, so a cover on a cross-user list costs two statements per distinct maker (`page_query_budget_test.rb`, "explore#index")."* **If open question 1 is answered "give `/explore` covers", this becomes `works` instead** — write whichever the decision produced, and do not write `works` over the placeholder.
  - Update the Coverage table: on the default above T5 becomes `8 | 1 works | 4 rough | 3 missing` and `all` becomes `50 | 9 | 25 | 14 | 2`. **Recount from the table rather than trusting these numbers** — S4-2 may have moved rows in the same window.
  - Add the re-measurement line at the bottom, in the existing style: *"Re-measured after S4-5 (2026-09-07): 5.5 moved to `works`; 5.7 gained the header, the hero and covers on a maker's page and stays `rough`."*
- [ ] **Step 2: the overview.** In `docs/superpowers/plans/2026-09-07-stage-4-00-overview.md`, mark the S4-5 row landed with the PR number, and correct its territory line: the template is `app/views/public/files/view.html.erb` (named after the action), the partials live under `app/views/files/viewers/`, and no CSP change was needed (state what the new test pins instead).
- [ ] **Step 3: the gates.** `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci` green; the three legs' run counts identical (a ±2 assertion flap is `tinkerex#131`; anything structural is a bug — most likely a viewer assertion that should branch on a capability).
- [ ] **Step 4: commit, push, PR, record.** `git commit -m "S4-5 close-out: the stories re-tagged, the overview updated"`; `/finish-branch`; then `bin/log arc --from-pr <n>`.

---

## Self-review against the spec (§5's S4-5 row and §2 D5)

| spec item | task |
|---|---|
| a public file page carrying 3D, Measure (read-only), Gerber, KiCanvas, images, PDF and code | A steps 4–5 (the partials), B steps 5–6 (the page) |
| …over the public blob route, with the **named** URL where a viewer types off the extension | B step 6 (`named`), A step 4 (`_model3d`/`_kicanvas` keep the rule in their comments), B step 12 mutation 3 |
| the viewers arrive **as they are** (D5) — one definition, no public fork | A (one concern, eight partials, private suites green unedited), A step 11 mutation 1 |
| `Public::` never reads the session; `permits?` is the one answer | B step 5 (`deliverable!`), A step 7 (the seam guard reaches the shared partials), A step 11 mutation 5 |
| bytes stay out of Rails; `Delivery`'s three mechanisms unchanged | B step 5 (`#show` untouched; `#view` renders markup only), Task D |
| Measure is read-only and keeps print + SVG export | Amendment 4, B step 1's Measure test |
| a visitor's poll never writes; a stale payload still resolves | Amendment 5, B step 5, B step 12 mutations 4 and 5 |
| covers on public cards and `/explore` | **PARTIAL.** C steps 3–4 give `/u/:handle` covers (mutations 1, 5, 6); `/explore` keeps the placeholder — Amendment 9, priced by C step 12 mutation 2, decided by open question 1. Story 5.7 re-tags `rough` accordingly. |
| a cover must be permitted before it is shown | C step 5, C step 12 mutation 3 |
| a minimal public header: site name → `/explore`, author → `/u/:handle`, an intro on `/explore` | C step 6, C step 12 mutation 4 |
| CSP: the viewers' fetch works on s3 too | B step 1's `connect-src` test (branches on `presignable?`, so all three legs pin their own answer) |
| query cost asserted, constant in N | B step 9 (`public files#view`), C step 9 (`public users#show`, `explore#index`) |
| the template sweep renders every viewer partial from BOTH pages | A step 9 (four private pages), B step 10 (two public pages) |
| class names are a contract; components only in `components.css` | C step 7 (`.public-header` in `shell.css`, no component redeclared), `css_hygiene_test.rb` |
| no new Stimulus controller | Tech Stack; `stimulus_hygiene_test.rb` unedited and run in A step 6 |
| stories re-tagged in the same PR | E |

---

## Open questions the implementer must NOT decide alone

1. **Does `/explore` get covers, and at what price?** The spec's S4-5 row asks for them; this plan ships them on `/u/:handle` only, because `page_query_budget_test.rb`'s explore seed mints **one owner per project** and `Maker::Previews::ThumbnailMap` is per-user by construction — a preview row belongs to its owner and the port is asked in the owner's name (§14a). Task C step 12 mutation 2 measures the actual per-maker delta; read those two numbers before choosing. The three options:
   - **(a) Ship as planned.** `/explore` cards show the placeholder, story 5.7 stays `rough`. Constant, no new abstraction, and the budget test now *proves* the constraint rather than merely asserting today's shape.
   - **(b) A per-owner map.** A small `Maker::Previews::CoverMap` grouping projects by owner and holding one `ThumbnailMap` each — the code is ~15 lines and reads well. It costs two statements per **distinct maker** on the page, bounded by `Public::ExploreController::PAGE = 60` but genuinely linear in the seed, so the budget test's `explore#index` case would have to be changed from "constant" to something weaker, and weakening a budget assertion is exactly what §15 says to argue in review rather than do.
   - **(c) Image-role covers inline, no previews at all.** One extra cross-user `nodes` query for the whole page (constant), and an image-role cover renders as `<img src=public_file_path(...)>` — the bytes *are* the picture, so there is no currency question and no per-owner port call. Two costs to weigh: a non-image cover (an STL) shows the placeholder even though a server thumbnail exists, and each card image is a real request to `Public::FilesController#show`, which builds a whole `Maker::PublicProject` (a `LibraryTree` over every live dir plus a folder listing) per image — 60 of those for a full page, where today the same route serves only a README's handful of images. `loading="lazy"` blunts it; it does not remove it.

2. **Should a visitor's page render be allowed to enqueue a geometry job at all?** Amendment 5 says yes, guarded by `current_preview` so it is one job per `(node, content token, renderer build)` and idempotent across reloads. The brief's instruction was *"the public one must NOT enqueue on a visitor's behalf; serve what exists or 404"*, which this honours for the **endpoint** and knowingly does not for the **render**. The evidence for the render enqueue: `kind: "geometry"` has exactly two enqueue sites today, both inside `FilesController#geometry` — so without it, public Measure works only for a file its owner has already measured, which is most of story 5.5 undelivered; and the public project page has backfilled *thumbnails* for every listed node on every anonymous visit since S3-4 (`public_project.rb:276-278`), so unauthenticated enqueueing is already the deployed posture. The conservative alternative is to drop `enqueue_geometry` entirely and let `#geometry` answer `{"status":"unsupported", "error":"This file has not been measured yet."}` when no row exists — one line each, the Measure button then reports that and restores the poster. **Decide before Task B, not during it.**

3. **Should `public/projects/_schematics.html.erb`'s list links move to the view page?** Task B leaves them at `download: true` and only corrects the partial's now-false comment, because a KiCad list sitting beside an inline KiCanvas embed already shows the board and D5 asks for the viewers a file page has, not for re-plumbing a panel. If the intent is that *every* file name on a public page opens its file page, `_schematics` is the one exception left and should change in the same PR.

4. **Is the CSP genuinely unchanged?** Read: `connect-src` is set on `ActionController::Base` and its Proc only calls `FileLayer.current`, so a `Public::` response carries the same header — and the anonymous-nonce fix (`content_security_policy.rb:136-138`) is already driven on a logged-out page by `content_security_policy_test.rb:109`. **Not verified in a browser on the s3 leg**, and no system test can: `test/system/` has no public file page today and the share leg would pass either way. The new integration assertion (B step 1) pins the header per leg, which is the strongest check available in `bin/ci`; the residual risk is the bucket's own CORS rule, which Rails cannot set (`docs/DEPLOY.md`) and which is an operator step after the first s3 deploy. If a browser-tier check is wanted, the cheapest is one `test/system/` case visiting the public file page for the `.stl` and asserting `.model-viewer[data-modelviewer-state='ready']` after clicking **View in 3D** — that is a real cross-origin fetch on the s3 leg and roughly the shape `o3dv_test.rb` already has. It is **not** in this plan's scope; say whether to add it.

5. **Does the phone sweep need a public file page at all, or is the integration suite enough?** Task C step 10 adds one entry to `test/system/shell_test.rb`'s public loop, which is the only check that the anonymous header plus a viewer's chrome does not scroll sideways at 375px — a real risk, since the Gerber and Measure bars carry five or six controls each and that loop's own header records that the `.public-files` column drops buy readability rather than overflow safety. It costs one more browser page in a suite that is already the slowest gate. Keep it unless the sweep's runtime is the binding constraint; if it is dropped, say so in the PR rather than leaving the omission to be discovered.
