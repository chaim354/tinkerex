# Public-surface hardening: tinkerex#278, #279, #283 — implementation plan

> **For agentic workers:** execute per `.claude/commands/execute-plan.md` — batch by FILE, run the
> three tasks in PARALLEL, one capped full-depth review per task that re-runs its mutations.

**Goal:** close the three public-surface findings the stage-4 reviews filed — a visitor's picture of
a file must die with the project's publication (#278), an anonymous request to `/u/:handle` must be
bounded (#279), and the documents that ride beside a public page (feed, bundle manifest, BOM CSV)
must honour the panel layout the page honours (#283).

**Architecture:** no new table. One new public door (`Public::FilesController#preview`) that asks the
SAME permission the byte route asks and then redirects to a service URL that expires; a page cap plus
offset paging on `/u/:handle`; and three side documents reading `Maker::PublicProject#panel_visible?`.
The shared interface — the route `public_file_preview`, `Maker::PublicProject#preview_url_for` and
`#panel_visible?` — is ALREADY COMMITTED on this branch so no task waits on another.

**Tech stack:** Rails 8.1, Active Storage (`:local` disk service in production), Minitest, Hotwire.

**Branch:** `claude/public-surface-hardening` off main `988a894`. Rules that bind here: CLAUDE.md
§14d (`Public::` never reads the session; `Maker::PublicProject#permits?` is the ONE answer to "is
this file public"), §14e (query cost is asserted as constancy), §15 (mutation-check every guard),
`docs/invariants/files-preview.md` (the eight viewer partials take every URL as a strict local),
`docs/invariants/design-system.md` (component selectors live in components.css).

## Decisions (the orchestrator's; state them in the PR, do not re-decide)

1. **A derived asset is served through the project's permission, not a signed blob URL.** Today every
   public surface renders `url_for(preview.asset)` — `/rails/active_storage/blobs/redirect/<signed_id>/…`
   with NO expiry (`ActiveStorage.urls_expire_in` is nil), so a cover thumbnail keeps answering after
   the project goes private, and forever. The alternative — a global `urls_expire_in` — breaks
   `loading="lazy"` images a visitor scrolls to after the window, and still checks nothing. The new
   route checks `deliverable!` per request and redirects to `blob.url` (the disk service URL, 5 min).
2. **The shared partials build no URL.** `files/_thumb` and the four viewer partials that render a
   thumbnail take the URL as a strict local from their caller. Private callers pass `preview_src(thumb)`
   (`url_for`, unchanged behaviour); public callers pass `pub.preview_url_for(node_id)`. The seam
   guard gains an arm: no `url_for` in `app/views/files/viewers/*` or `files/_thumb.html.erb`.
3. **The owner's preview of a PRIVATE project already renders dead byte URLs** (`file_url_for` → the
   public route → 404 while private); thumbnails now behave the same. Not fixed here — filed as open
   work with the proposed fix (`Maker::PublicProject.new(project, urls: :owner)`); the preview of a
   PUBLISHED project is unaffected.
4. **`/u/:handle` pages at 60, newest first, with `?page=N`.** Same `PAGE` as `/explore`; a page past
   the last is a 404; `page` that is not a positive integer reads as 1. The head keeps the TOTAL.
5. **A hidden panel's document is absent, not empty-but-present:** the feed drops the hidden kind's
   items; the manifest lists no files when `attachments` is hidden and carries no `bom_csv_url` when
   `bom` is; the CSV answers 404 when `bom` is hidden; the page shows no Feed link (and no Atom
   `<link>`) when neither `build_log` nor `releases` is visible. `readme_path` is untouched: the README
   renders OUTSIDE the panel loop (`_page.html.erb:82`), so it has no panel to hide with.

## File structure (batched; the three tasks touch DISJOINT files except one shared template)

| task | owns |
|---|---|
| A (#278) | `app/controllers/public/files_controller.rb`, `app/helpers/application_helper.rb`, `app/views/files/_thumb.html.erb` and its 13 render sites (10 private, 3 under `app/views/public/projects/`), `app/views/files/viewers/{_static,_model3d,_measure,_gerber}.html.erb` + their two call sites (`app/views/files/show.html.erb`, `app/views/public/files/view.html.erb`), `app/views/public/_project_card.html.erb`, `app/views/public/projects/_page.html.erb` (the HERO lines only), `test/architecture_invariants_test.rb`, `test/support/public_fixture.rb` (`assert_no_private_urls`), NEW `test/integration/web/public_preview_test.rb`, `docs/invariants/files-preview.md` |
| B (#279) | `app/controllers/public/users_controller.rb`, `app/views/public/users/show.html.erb`, `app/assets/stylesheets/components.css` (a pager, only if none exists), NEW `test/integration/web/public_user_page_test.rb` |
| C (#283) | `app/services/maker/public_project.rb`, `app/controllers/public/bundles_controller.rb`, `app/controllers/public/boms_controller.rb`, `app/views/public/projects/show.html.erb`, `app/views/public/projects/_page.html.erb` (the FEED LINK lines only), `app/javascript/controllers/bundle_controller.js`, `test/integration/web/public_feed_test.rb`, `test/integration/web/public_bundle_test.rb` |

`_page.html.erb` is shared between A (hero, ~line 113) and C (Feed link, ~line 41): re-read before
every Edit, edit with the Edit tool only, never Write the whole file.

---

### Task A: the picture of a public file dies with its publication (#278)

**Step 1 — the door.** In `Public::FilesController`, `include ActiveStorage::SetCurrent` (so
`blob.url` can build an absolute disk-service URL from this request) and add:

```ruby
    # GET /u/:handle/:slug/files/:id/preview/:kind — a file's DERIVED asset: its thumbnail, or the
    # Measure payload (hardening, 2026-09-08; tinkerex#278). THE SAME PERMISSION AS THE BYTES
    # (`deliverable!`), then a redirect to a service URL that EXPIRES (`ActiveStorage.service_urls_expire_in`,
    # 5 minutes) — where `url_for(preview.asset)` handed out a signed blob URL with no expiry at all,
    # so a cover kept answering after the project went private. `current_preview` is the same
    # "current content, current renderer build" rule the page rendered from; a row that is not ready
    # is a 404 like a node that is not permitted, because an <img> cannot use a status.
    def preview
      pub = public_project!
      node = pub.deliverable!(params[:id])
      token = FileLayer.current.stat(pub.owner, node_id: node.node_id)&.content_token
      row = token && Maker::Previews::Enqueue.current_preview(user: pub.owner, node_id: node.node_id,
                                                              name: node.name, version_id: token,
                                                              kind: params[:kind])
      raise ActiveRecord::RecordNotFound unless row&.status == "ready" && row.asset.attached?

      redirect_to row.asset.url, allow_other_host: true
    end
```
and in `#geometry` replace `url_for(preview.asset)` with `pub.preview_url_for(node.node_id, kind: "geometry")`
(`pub` is already local there).

**Step 2 — the helper.** `ApplicationHelper#preview_src(preview)`: `url_for(preview.asset)` when
`preview&.status == "ready" && preview.asset.attached?`, else nil. It is the ONE private spelling.

**Step 3 — `files/_thumb`.** Strict locals become `(thumb:, ext_label:, url:)`; the ready branch renders
`url`. Update all 13 render sites: the 10 private ones pass `url: preview_src(<the same thumb expr>)`;
the 3 public ones (`public/projects/_files`, `_photos`, `_build_log`) pass `url: pub.preview_url_for(<node_id>)`.

**Step 4 — the viewers.** `_static`, `_model3d`, `_measure`, `_gerber` gain a REQUIRED local
`thumbnail_url:` and render it where they rendered `url_for(thumbnail.asset)`. `files/show.html.erb`
passes `thumbnail_url: preview_src(@thumbnail)`; `public/files/view.html.erb` passes
`thumbnail_url: @pub.preview_url_for(@node.node_id)`. Read `docs/invariants/files-preview.md`'s
"THE EIGHT VIEWER PARTIALS ARE SHARED" rule first.

**Step 5 — the two remaining emitters.** `public/_project_card.html.erb`: `thumb` is a `Maker::Preview`
and carries `node_id`, so the src is `public_file_preview_path(project.user.handle, project.slug, thumb.node_id, "thumbnail")`
(a listed project is never unlisted, so no token). `public/projects/_page.html.erb` hero:
`pub.preview_url_for(cover.node_id)`.

**Step 6 — the guards.** (a) In `test/architecture_invariants_test.rb`, a third arm beside the
route-helper arm: the viewer partials AND `app/views/files/_thumb.html.erb` contain no `\burl_for\b`
outside ERB comments; assert the scanned set is non-empty. (b) `assert_no_private_urls` (find it in
`test/support/public_fixture.rb` or the test that defines it) additionally refuses
`/rails/active_storage/` — so EVERY public suite sweeps for a blob URL from now on.

**Step 7 — the tests** (`test/integration/web/public_preview_test.rb`, `include PublicFixture`, copy
`ready_cover!` from `public_project_test.rb:345` into a helper that makes a READY thumbnail row with an
attached asset for any node, and a ready `geometry` row for a `.lbrn2`):
- the handle page, the project page (hero from a NON-image cover with a ready thumb; a photo row; a
  file row), the file view page for a `:static` kind and a `:model3d` kind, and the geometry JSON —
  each body contains the public preview route and no `/rails/active_storage/`;
- `GET preview_url` → 302 whose Location matches `%r{/rails/active_storage/disk/}`; `follow_redirect!`
  → 200 with the asset's bytes;
- after `project.update!(visibility: "private")` the same URL → 404; unlisted needs `k` (no `k` 404,
  right `k` 302); a node outside the folder and unattached → 404; a node with no ready row → 404;
  `/preview/other` → routing error / 404 (assert with `assert_raises(ActionController::RoutingError)`
  or `assert_response :not_found` — whichever the app maps unmatched routes to; check by driving it).
- the private file page still renders `/rails/active_storage/` for its own thumbnail (unchanged).

**Step 8 — mutations, report each output:** (i) restore `url_for(thumb.asset)` in `_project_card` →
the sweep test AND `assert_no_private_urls` go red; (ii) restore `url_for(thumbnail.asset)` in
`_static` → the architecture guard's new arm goes red; (iii) drop `deliverable!` for a bare
`owner.nodes.find_by` in `#preview` → the unpermitted-node test goes red; (iv) replace the redirect
with `redirect_to rails_storage_redirect_path(row.asset)` → the Location assertion goes red (that URL
does not expire — the whole point).

**Step 9 — docs.** One paragraph in `docs/invariants/files-preview.md` under the viewer-partials rule:
"A DERIVED ASSET OF A PUBLIC FILE IS SERVED THROUGH `public_file_preview`, NEVER `url_for(asset)`",
naming the guard arms and decision 3 (the owner preview of a private project).

**Step 10 — commit** (message via `-F`, pathspec-limited to A's files).

---

### Task B: `/u/:handle` is bounded (#279)

**Step 1.** `Public::UsersController`: `PAGE = 60` (same as `ExploreController::PAGE`); `page` from
`params[:page]` — `to_i`, anything below 1 reads as 1; `@total = scope.count`; `@pages = [(@total.to_f / PAGE).ceil, 1].max`;
`raise ActiveRecord::RecordNotFound if page > @pages`; `@projects = scope.order(updated_at: :desc, id: :desc).limit(PAGE).offset((page - 1) * PAGE).to_a`
(the `id` tie-break makes paging stable when two projects share an `updated_at`); `@page = page`.
Keep the `includes(:tags, :file_attachments)` and the cover map exactly as they are — the map is now
over at most PAGE covers, which is the bound the issue asks for. Write the comment: why a COUNT is
worth one query (the head says the total), why offset paging is enough here, and what the bound
protects (an anonymous request stats N nodes and renders N cards).

**Step 2.** `public/users/show.html.erb`: the head shows `pluralize(@total, "public project")`; below
the grid, when `@pages > 1`, a pager: `Page N of M`, `Newer` (`public_user_path(@owner.handle, page: @page - 1)`,
page 1 omits the param) and `Older` links, each rendered only when it exists. Reuse an existing pager
component if the stylesheet has one (`grep -n "pager\|pagination" app/assets/stylesheets/*.css`);
otherwise add a minimal `.pager` to `components.css` following `docs/invariants/design-system.md`.

**Step 3 — tests** (`test/integration/web/public_user_page_test.rb`, `include PublicFixture`,
`make_owner!`; projects need NO folder — `owner.maker_projects.create!(name:, visibility: "public", status: "active")`
after the handle is set, as `page_query_budget_test.rb:1078` does): with `PAGE + 1` public projects,
page 1 renders exactly 60 `.project-card`, page 2 renders 1, the head says 61, page 1 has Older and no
Newer, page 2 the reverse, `page=3` → 404, `page=0` and `page=abc` render page 1; an UNLISTED project
never appears on any page (mutation: swap `publicly_listed` for `published` → red); the newest project
is first on page 1 and the oldest last on page 2. Run `bin/rails test test/integration/web/page_query_budget_test.rb -i "/public users#show/"`
and report it green: the count query is constant.

**Step 4 — mutations:** (i) remove `.limit(PAGE)` → the 60-card assertion goes red; (ii) remove the
`> @pages` 404 → the `page=3` test goes red; (iii) `published` for `publicly_listed` → red.

**Step 5 — commit** (`-F`, pathspec).

---

### Task C: the side documents honour the panel layout (#283)

**Step 1 — the model** (`Maker::PublicProject`, `#panel_visible?` already exists): `feed_items` takes
`newest_entries = []` unless `panel_visible?("build_log")` and `newest_releases = []` unless
`panel_visible?("releases")`; `bundle_files` answers `[]` unless `panel_visible?("attachments")`
(memoise the empty answer too). Comment each with the rule in decision 5.

**Step 2 — the controllers.** `BundlesController`: `bom_csv_url: (public_bom_path(...) if pub.panel_visible?("bom"))`
and `truncated: pub.panel_visible?("attachments") && pub.listing.truncated?`. `BomsController`:
`return head :not_found unless pub.panel_visible?("bom")` before rendering.

**Step 3 — the page.** In `public/projects/_page.html.erb` wrap the Feed link (~line 41) in
`<% if pub.panel_visible?("build_log") || pub.panel_visible?("releases") %>`; in
`public/projects/show.html.erb` gate the Atom `<link rel="alternate">` the same way. The bundle button
already disappears on its own (`bundle.any?` over an empty `bundle_files`) — say so in a comment there,
do not add a second condition. Task A edits the HERO lines of `_page.html.erb` concurrently: re-read
before each Edit.

**Step 4 — the script.** `bundle_controller.js`: fetch and add `bom.csv` only when `manifest.bom_csv_url`
is present; the status line's file count is unchanged.

**Step 5 — tests.** In `public_feed_test.rb`: hide `build_log` → the feed carries the release items and
no entry item; hide `releases` → the reverse; hide both → the feed is valid Atom with zero entries AND
the project page has no `.feed-link` and no `link[type="application/atom+xml"]`; a page with either
visible still links the feed. In `public_bundle_test.rb`: hide `attachments` → the page has no
`.bundle` button, the manifest has `files: []`, `truncated: false` and STILL a `readme_path`; hide `bom`
→ the manifest's `bom_csv_url` is null and `GET /bom.csv` is 404, while the CSV answers 200 with the
panel visible. Set the layout with `project.update!(panels: { "hidden" => %w[bom] })` (the shape
`project_page_test.rb:269` uses).

**Step 6 — mutations:** (i) drop the `build_log` gate in `feed_items` → red; (ii) drop the `bom` gate in
`BomsController` → the CSV 404 test goes red; (iii) drop the `attachments` gate in `bundle_files` → red
on the manifest and the button.

**Step 7 — commit** (`-F`, pathspec).

---

### Task D: close-out (orchestrator)

- `bin/log open` for decision 3 (the owner's preview of a private project renders dead public URLs).
- `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci` — every gate green,
  the three legs at identical run counts.
- Push, `gh pr create --base main`, `bin/log arc --from-pr N`. **No merge without the owner's go-ahead**
  — the stage-4 standing authorization does not cover this branch.
