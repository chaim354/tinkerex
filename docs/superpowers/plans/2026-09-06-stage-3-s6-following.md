# Stage 3, S3-6: Following — the feed and the bundle export

> **For agentic workers:** execute per `.claude/commands/execute-plan.md`. Steps use checkbox
> (`- [ ]`) syntax. Stacked on S3-5 (`claude/stage-3-releases`): the feed lists releases.

**Goal:** a public project has an Atom feed of its build log and releases, and a "Download
bundle" that hands a visitor one zip holding the project's files at their folder-relative paths,
`bom.csv`, and the README — assembled in the visitor's browser from the same public file route the
page already links, so the bytes never pass through Rails on any backend beyond what a plain
download already does.

**Architecture:** spec §4 (S3-6), §6. Two sessionless `Public::` doors: `Public::FeedsController#show`
(`/u/:handle/:slug/feed.atom`, unlisted needs `k`) rendering an `atom_feed` builder over entries
and releases merged newest first, capped; and `Public::BundlesController#show`
(`/u/:handle/:slug/bundle.json`) answering a MANIFEST — name, version, README node, every permitted
file with its folder-relative path, size and public download URL, and the URL of `bom.csv`
(`Public::BomsController#show`, `/u/:handle/:slug/bom.csv`). A Stimulus controller
(`bundle_controller.js`) fetches the manifest, fetches each file through the public route, adds
`bom.csv`, and builds the zip with the vendored JSZip (MIT), then offers it through an `<a download>`
on a Blob URL. **On the s3 deployment the public file route redirects to a presigned URL and the CSP
(`default-src 'self'`, no `connect-src`) blocks that fetch — the same shared follow-up KiCanvas and
the 3D viewer already carry (S3-2); the button says so when a fetch fails rather than failing
silently.**

**Tech:** Rails builder templates (`atom_feed`), `Maker::PublicProject`, JSZip 3.10.1 (already
pinned), CSV (already in the Gemfile for `Maker::Sheet#to_csv`).

---

## Rounds

One implementer (Task A: everything), then one capped review. Base branch:
`claude/stage-3-following` from `claude/stage-3-releases`' head. Same rules as every slice:
pathspec commits, `git checkout --` restores, mutations with actual output, the four derived guards
where they apply (no new table here: only `template_hygiene` and the budgets).

---

## Task A

### A.1 Routes

Inside the `scope module: :public, as: :public do` block:

```ruby
    get "u/:handle/:slug/feed",    to: "feeds#show",   as: :feed,   constraints: { handle: /[a-z0-9][a-z0-9-]*/i }, defaults: { format: :atom }
    get "u/:handle/:slug/bundle",  to: "bundles#show", as: :bundle, constraints: { handle: /[a-z0-9][a-z0-9-]*/i }, defaults: { format: :json }
    get "u/:handle/:slug/bom",     to: "boms#show",    as: :bom,    constraints: { handle: /[a-z0-9][a-z0-9-]*/i }, defaults: { format: :csv }
```

(`public_feed_path(h, s)`, `public_bundle_path`, `public_bom_path`; all three pass `k` through
`link_params` for an unlisted project. Place them BEFORE the `files/:id` route or after — they do
not overlap; keep `format: false` off these three so `.atom`/`.csv`/`.json` may be spelled.)

### A.2 The feed

`Public::FeedsController#show`: `@pub = public_project!`; `@items = @pub.feed_items` — a method on
`Maker::PublicProject` answering at most `FEED_CAP = 50` items, each `FeedItem = Data.define(:kind, :id, :title, :time, :html, :url)`:
every build-log entry (`kind: :entry`, title "Build log — <date>", `html: entry.body.to_s` — Action
Text's rendered HTML, `time: logged_at`) and every release (`kind: :release`, title
"Release <version>", `html: release.notes.to_s + a file count line`, `time: published_at`), merged
and sorted by time desc, then capped. The entry URL is the public project page (anchors
`#entry-<id>` / `#release-<id>` — add those ids to both panels' rows on the public page). Render
`app/views/public/feeds/show.atom.builder`:

```ruby
atom_feed(root_url: public_project_url(@pub.handle, @pub.project.slug, **@pub.link_params),
          url: public_feed_url(@pub.handle, @pub.project.slug, **@pub.link_params),
          id: "tag:tinkerex,#{@pub.project.created_at.to_date}:project/#{@pub.project.id}") do |feed|
  feed.title "#{@pub.project.name} — @#{@pub.handle}"
  feed.updated(@items.first&.time || @pub.project.updated_at)
  @items.each do |item|
    feed.entry(item, id: "tag:tinkerex,#{item.time.to_date}:#{item.kind}/#{item.id}", url: item.url, updated: item.time, published: item.time) do |e|
      e.title item.title
      e.content item.html, type: "html"
      e.author { |a| a.name "@#{@pub.handle}" }
    end
  end
end
```

`feed.entry(record, …)` expects an ActiveRecord-ish object for its default id/url; pass `id:` and
`url:` explicitly as above (and `updated:`/`published:`), so a `Data` item works — verify by
rendering. A private project → 404; unlisted → `k`. `<link rel="alternate" type="application/atom+xml">`
in the public project page's `content_for :head`, and a small "Feed" link in the page head beside
the byline.

### A.3 The manifest and the BOM CSV

`Public::BundlesController#show` renders JSON (no view file: `render json:`):

```ruby
{ name: project.name, handle:, slug:, generated_at: Time.current.iso8601,
  files: pub.bundle_files.map { |f| { path: f.path, size: f.size, url: f.url } },
  bom_csv_url: public_bom_path(handle, slug, **link_params), readme_path: pub.readme_row&.then { |r| r.node.name } }
```

`Maker::PublicProject#bundle_files`: every row in `listing.all_rows` that is not a backup, mapped to
`BundleFile = Data.define(:path, :size, :url)` with `path` folder-relative (`docs/pinout.pdf`,
the README at the root as `README.md`), `url: file_url_for(node_id, download: true)`. The files
are the listing's — which is capped (`FILE_CAP`) — and the manifest says so: `truncated: listing.truncated?`
(the button renders "first N files" then). No `permits?` per row is needed: every listing row is
permitted by construction (ancestry), which the service already relies on for the page.

`Public::BomsController#show`: `send_data csv, type: "text/csv", disposition: "attachment", filename: "#{slug}-bom.csv"`
where `csv = Maker::BomCsv.render(pub.bom_lines, pub)` — a new small service (`app/services/maker/bom_csv.rb`)
writing `reference,part,quantity,unit,file` with the SAME rule as the public BOM partial: part is
the inventory item's name / the file's name (only when `pub.permits?`) / the part name; NO stock, NO
supplier, NO notes. An empty BOM → a header-only CSV. Reuse it later for the private BOM page if
wanted; not now.

### A.4 The button and `bundle_controller.js`

On the public project page head, when `@pub.bundle_files.any?`: a `div.bundle` with
`data-controller="bundle" data-bundle-manifest-value="<%= public_bundle_path(...) %>" data-bundle-name-value="<%= @project.slug %>"`,
a `button.btn.small` "Download bundle (N files, X MB)" with `data-action="bundle#build"`, and a
`span.muted[data-bundle-target="status"]`. The controller:

```js
import { Controller } from "@hotwired/stimulus"
import JSZip from "jszip"

// THE BUNDLE IS BUILT HERE, IN THE VISITOR'S BROWSER, from the same public file route the page
// links — never by Rails zipping bytes (CLAUDE.md §15; on s3 the route REDIRECTS to the store,
// and a server-side zip would pull every byte through the app). Sequential fetches, so a folder of
// large STLs does not open a hundred connections at once; a failed fetch stops the build and names
// the file, which on the s3 deployment is the CSP follow-up S3-2 recorded (connect-src).
export default class extends Controller {
  static targets = ["status"]
  static values = { manifest: String, name: String }
  static MAX_BYTES = 500 * 1024 * 1024

  async build(event) {
    event.preventDefault()
    const button = event.currentTarget
    button.disabled = true
    try {
      const manifest = await (await fetch(this.manifestValue, { headers: { Accept: "application/json" } })).json()
      const total = manifest.files.reduce((n, f) => n + (f.size || 0), 0)
      if (total > this.constructor.MAX_BYTES) { this.say(`Too large to bundle in the browser (${this.mb(total)} MB).`); return }
      const zip = new JSZip()
      let done = 0
      for (const file of manifest.files) {
        this.say(`Fetching ${++done} of ${manifest.files.length}: ${file.path}`)
        const res = await fetch(file.url)
        if (!res.ok) throw new Error(`${file.path}: ${res.status}`)
        zip.file(file.path, await res.blob())
      }
      const bom = await fetch(manifest.bom_csv_url)
      if (bom.ok) zip.file("bom.csv", await bom.blob())
      this.say("Compressing…")
      const blob = await zip.generateAsync({ type: "blob" })
      const a = document.createElement("a")
      a.href = URL.createObjectURL(blob)
      a.download = `${this.nameValue}-bundle.zip`
      a.click()
      setTimeout(() => URL.revokeObjectURL(a.href), 60_000)
      this.say(`Bundled ${manifest.files.length} files (${this.mb(blob.size)} MB).`)
    } catch (e) {
      this.say(`Could not build the bundle — ${e.message}. Files can still be downloaded one at a time.`)
    } finally {
      button.disabled = false
    }
  }

  say(text) { this.statusTarget.textContent = text }
  mb(bytes) { return (bytes / 1048576).toFixed(1) }
}
```

`test/stimulus_hygiene_test.rb` derives identifiers from filenames — the `data-controller="bundle"`
in the view must match `bundle_controller.js`. The `fetch` of the public file route follows the
redirect on s3 (blocked by CSP today) and streams on chunk_remote; on share it is `send_file`.

### A.5 Tests

- `test/integration/web/public_feed_test.rb`: the Atom document parses (Nokogiri XML), one `entry`
  per build-log entry and release, newest first, capped at `FEED_CAP` (seed `FEED_CAP + 2`), entry
  content is HTML (`type="html"`) and a `<script>` in an entry body never appears (Action Text is
  text-only already; assert anyway), a private project → 404, unlisted needs `k` and the feed's
  links carry it, the page's `<link rel="alternate" type="application/atom+xml">` points at the
  feed. Mutation: drop the cap → red; `sort_by` ascending → the newest-first test.
- `test/integration/web/public_bundle_test.rb`: the manifest lists every non-backup file with a
  folder-relative path, size and a URL that resolves (GET it → delivered, branching on
  `presignable?` like `public_file_test.rb`), excludes a backup and a dot-file, carries `k` when
  unlisted, `truncated` false; the BOM CSV has the header + one row per line with the public
  partial's part rule and no stock/supplier column; an empty BOM → header only; a private project →
  404 for all three routes. Mutation: `reject(&:backup?)` dropped → the backup appears; the CSV's
  part rule reads `node&.name` unguarded → a line pointing outside the project names the file.
- `test/services/maker/bom_csv_test.rb`: the three target kinds, quoting of a comma in a part
  name (CSV handles it), the outside-project file → the part name or blank.
- `test/system/public_bundle_test.rb`: with a real share library and two small files, click
  "Download bundle" and assert the status reaches "Bundled 2 files" and no console errors — the
  browser downloads to a temp dir; asserting the status text is enough (do not assert the file
  landed on disk: headless Chrome's download dir varies). Add the public project page to nothing
  new in the phone sweep — it is already visited; the button and status must not overflow at 375px.
- `template_hygiene_test.rb`: no new HTML partial (the builder is not swept; the button lives in
  `show.html.erb`). `page_query_budget_test.rb`: the manifest and the feed constant in files /
  entries / releases (two small budgets).

### A.6 Docs

The spec's §6 gains one line: "The bundle is built in the browser from the public file route; Rails
never zips bytes." `docs/invariants/files-preview.md` is not the place; no CLAUDE.md change (the
ceiling is full).

---

## Self-review against the spec

- §4 S3-6 "the build log and releases as a feed per public project" → A.2; "a project bundle export
  (files, BOM as CSV, README)" → A.3/A.4 (the README is a file in the manifest; `bom.csv` is added).
- §6 "bytes never pass through Rails on s3 or chunk_remote beyond what a download already does" —
  the bundle reuses the download route per file; the s3 CSP caveat is named on the button and in
  the PR.
- Out: following as a social feature (there is no account-side "follow"), email digests, a private
  bundle button (cheap to add later: the manifest's file URLs would be the blob routes).
