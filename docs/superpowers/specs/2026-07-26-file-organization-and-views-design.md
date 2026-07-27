# File organization and views — design

**Date:** 2026-07-26
**Status:** approved, ready for an implementation plan
**Surface:** the web UI's Files pages (`FilesController`, `app/views/files/`) and
`Projects::AttachmentsController`. Nothing below touches sync, the changelog, conflicts, locks or
the mounts — the maker/file-layer split's §10 tripwire stays un-tripped.

---

## 1. Why

Four gaps in the current Files UI, all reported together because they are one workflow — finding a
file and putting it where it belongs:

1. The file page's "Attach to project" control renders **one button per project**, so a maker with
   fifteen projects gets fifteen buttons.
2. The list view has **no sorting** — rows always come back `kind: :desc, name: :asc`.
3. Attaching a file to a project is **pure bookkeeping**: the bytes stay wherever they were, so the
   project's library folder and the project's attachment list disagree about what the project
   contains.
4. There is **no way to see every file of a type** — all the `.stl`s in one list — because the only
   navigation is one folder at a time.

---

## 2. Scope

**In:** the attach dropdown, multi-project attachment display, auto-move-on-attach with a
collision prompt, list sorting, and a flat by-extension filter.

**Out (explicitly):** pagination of the folder view (unchanged, still unbounded — see §6.4 for the
one bounded case this adds), a size sort (§5.3), drag-and-drop file moving, saved/named filter
groups, and any change to how bytes are stored or delivered.

---

## 3. Attach control on the file page

### 3.1 The dropdown

`app/views/files/show.html.erb` replaces the `@projects.each { button_to }` row with one form
containing a `<select name="project_id">` of this user's non-archived projects **minus** the ones
this file is already attached to, a hidden `node_id`, and an "Attach" submit button.

The existing route is nested — `POST /projects/:project_id/attachments` — so the project would have
to be in the form's *action*, which a `<select>` cannot set without JS. Rather than add a Stimulus
controller to rewrite `action` on change, this adds **one non-nested route**:

```ruby
post "attachments" => "projects/attachments#create", as: :attachments
```

`Projects::AttachmentsController#set_project` already reads `params[:project_id]`, which resolves a
body param and a path segment identically, so **the controller is unchanged** and both routes reach
the same action. No new JS. (`attachments_path` is free: the shallow `resources :attachments` under
`:projects` claims only `project_attachments_path` and the singular `attachment_path`.)

### 3.2 Already-attached projects are visible

Above the dropdown, the projects this file is already attached to render as chips, each with a `×`
that hits the existing `DELETE /attachments/:id`. This is what makes "a file can be attached to
multiple projects" a visible property rather than merely a permitted one — today the file page
gives no indication a file is attached to anything at all.

### 3.3 Duplicate guard

`maker_file_attachments` has no uniqueness index (`db/schema.rb` — only two non-unique indexes), so
`create!` twice makes two rows. `#create` becomes a `find_or_create_by(attachable:, node_id:)` with
the role assigned on create. No migration: a unique index would need a backfill dedupe, and the
controller is the only writer.

---

## 4. Auto-move into the project folder

### 4.1 The rule

On attach, move the file into the project's `Projects/<slug>/` folder **if and only if**:

- the file had **no other project attachment** before this one (the user's rule: a file already
  claimed by another project stays where it is), **and**
- it is not already in that folder.

Otherwise the attach happens and nothing moves.

The rule lives in `Projects::AttachmentsController#create`, so every attach path behaves the same:
the file-page dropdown, the project page's "attach existing file" picker, and the importer's
JSON attach. Tool and importer *uploads* already write directly into the project folder, so they
are unaffected (they arrive already in place, and the "already there" check short-circuits).

### 4.2 `Maker::MoveNode` — the third copy of a branch gets a name

The move is a two-door operation, exactly like folder creation:

```
port_writable? (share/s3) → FileLayer.current.move(user, node_id:, new_parent_node_id:, new_name:)
else            (chunk)   → Sync::Mutation.apply(user:, node:, op: "move") { |n| n.parent_node_id = … }
                            + LibraryChannel.broadcast_change(user, seq)
```

That branch already exists in `Maker::LibraryFolder` (mkdir) and `FilesController#destroy`
(delete). This is its third appearance, so it becomes a service — `Maker::MoveNode` — written to
mirror `Maker::LibraryFolder`'s shape and comments. Controllers call the service and never reach
into `Sync::` or the port directly; that seam is what keeps §10 honest.

`Sync::Mutation.apply(op: "move")` is the door `Chunk::MOVE_MSG` names and the one
`V1::NodesController#move` already uses. The `node_id` is preserved by both doors — that is the
port's stated promise and what keeps every attachment, BOM link and tag pointing at the same file.

### 4.3 Collision → a prompt, never a failed attach

Before moving, check for a live node with the same name under the destination folder
(`user.nodes.present.where(parent_node_id: dest, name:)`). This is a DB check, so it is
backend-neutral; `Share#move`'s `UnsupportedOperation` (`"…already exists"`) and `S3#write`'s
clobber refusal are the backstop for a race or an out-of-band file.

On collision:

1. **The attachment is still created.** An attach is bookkeeping and must never fail because of a
   filename — the same reasoning `AttachmentsController` already applies by checking ownership as a
   DB fact rather than a `FileLayer.stat`, so an unmounted backend cannot block it.
2. The redirect carries `?move_conflict=<attachment_id>`.
3. A shared partial (`app/views/shared/_move_conflict.html.erb`) renders a native `<dialog open>`
   on the redirect target — the file page or the project page, whichever the attach came from:

   > **"Bracket.stl" is already in Projects/lamp.**
   > `[ Move it in as "Bracket (2).stl" ]`  `[ Leave it where it is ]`

4. "Leave it where it is" is a link back to the same page without the param — it dismisses and
   nothing moves.
5. "Move it in as …" POSTs to `POST /projects/:project_id/attachments/relocate { node_id,
   new_name }`, which runs the same `Maker::MoveNode` with the suggested name.

The suggested name is `"<base> (2)<ext>"`, incrementing until free, capped at a small number of
tries; if no free name is found the dialog offers only "Leave it where it is".

**Why `relocate` and not a general `POST /files/:id/move`:** the conflict flow needs *a* move
endpoint either way, and the scoped one can only move a file into the named project's own folder.
A general move endpoint is a larger web surface than this feature needs, and nothing else wants it
yet.

A move failure that is *not* a collision — `FileLayer::FetchError` from an unmounted share, say —
also leaves the attachment in place and reports "Attached — couldn't move it into the project
folder right now." The attach is the durable half; the move is best-effort, in the same spirit as
`enqueue_preview` and `attach_addon_files_to_current_project`.

---

## 5. Sorting

### 5.1 The control

The list view's `Name`, `Type` and `Modified` headers become links that toggle
ascending↔descending: `?sort=type&dir=desc`, with an arrow (`▲`/`▼`) on the active column and
`aria-sort` on the `<th>`. The choice is remembered in a `files_sort` cookie exactly as the
list/grid choice is remembered in `files_view`, and resolved by the same whitelist idiom as
`resolve_view` — an unknown `sort`/`dir` (a junk query param or a tampered cookie) falls back to
the default rather than reaching the view as an arbitrary string.

Keys: `name` (A→Z), `type` (extension), `modified` (mtime). Default `name asc`, matching today's
`name: :asc` behavior.

Grid view renders the same choice as a compact `<select>`. This is free: the controller sorts
`@nodes` before either partial renders.

### 5.2 Sorting happens in Ruby, not in SQL

`name` and `mtime` are node columns and would sort fine in SQL, but **type means extension**, and
there is no expression for it that is portable across SQLite (self-host) and Postgres (managed) —
`substr`/`instr` and `substring`/`position` differ. Case-insensitive name ordering has the same
portability problem (`COLLATE NOCASE` vs `citext`/`lower()`).

The alternative — a denormalized, indexed `ext` column on `nodes` — would have to be populated by
every write path that creates a node, which includes `Sync::Commit` and `Sync::Mutation`. That is
writing to the sync layer to serve a web view: the §10 tripwire, and the boundary is wrong.

So all three keys sort in Ruby, over the full matched set, uniformly. One code path, no key that is
"exact" while another is approximate. The cost is the shape the controller already has: `#index`
loads the folder with `.to_a` and does an in-memory `select!` against `stat_all`'s keys today.

Secondary key is the existing `kind: :desc, name: :asc` grouping, so files and directories stay
grouped exactly as they are now and equal sort keys stay stable.

### 5.3 No size sort

Not requested, and it is the one key that is not a node column on every backend: `Chunk#stat_all`
reads size from the `versions` row (`nodes.size` is not its source of truth), while
`Share#stat_all` reads it straight off the node. A size sort would be the only inexact one, and an
inexact sort in a column of exact-looking numbers is worse than no sort.

---

## 6. Flat type filter

### 6.1 Behavior

`?ext=stl,3mf` switches `/files` from folder browsing to a **flat, whole-library list of just those
file types**, ignoring `params[:folder]` entirely. Clearing the filter returns to folder browsing at
the root. Multiple extensions compose, which is the "all stls and all 3mfs" case.

Rendered by the same `_list`/`_grid` partials with the same sort control — a filter is a different
row set, not a different page.

### 6.2 The chip row

Above the list, a row of extension chips. Each chip is a link that toggles its own extension into
or out of the `ext` param, so clicking `.stl` while `.3mf` is active yields `?ext=3mf,stl`. Active
chips are visually marked. A "Clear" link drops the param.

Chips come from a **curated known-extension list** — the union of the extensions
`Maker::Previews::Registry` can render and `Maker::FileAttachment::ROLE_BY_EXT` knows a role for —
grouped by family (models, laser/2D, documents, images). Alongside them sits a small text input,
"or an extension…", that appends an arbitrary extension to the param, so a user with `.f3d` files
is not blocked by our list.

**Why not real facet counts:** building "you have 214 .stl files" means plucking every filename in
the library and counting in Ruby — a full-library query on *every* Files page load, including plain
folder browsing that never uses the chips. A chip that matches nothing is a harmless dead end; a
query the folder view pays for and never reads is not. If real counts are wanted later, a cached
per-user facet count is the follow-up, not a per-request pluck.

### 6.3 Query and validation

Extensions are downcased and validated to `\A[a-z0-9]{1,8}\z`, with at most 8 accepted; anything
else is dropped. Matching is `lower(name) LIKE '%.stl'` OR-ed per extension, scoped to
`kind: "file"` and `nodes.present`. The validation is what keeps `ActiveRecord::Base.sanitize_sql_like`
sufficient and the query shape bounded.

The filter is **files only** — a directory has no extension and never appears in a type view.

### 6.4 The Folder column, and the one bound this feature adds

In flat mode the list gains a **Folder** column showing where each file lives; a flat list of 200
STLs with no location is unnavigable. Paths are built from one query for the user's `dir` nodes
(few, even in a large library) assembled into paths in Ruby — not a parent walk per row.

The flat result set is **bounded at 2000 files**, with a visible notice — "Showing the first 2000
of 3,412 matching files" — when the bound is hit. The Files page has never paginated, and the
Phase 4 follow-up measured a 2000-node page at ~160 ms of render on all three backends; a
library-wide view is the first thing here that can plausibly exceed that. The notice is the point:
a silent truncation reads as "that's all your STLs", which is the same class of lie as a paginated
listing mistaken for a snapshot. Pagination is the follow-up if a real library hits the bound.

---

## 7. Files touched

| File | Change |
|---|---|
| `app/controllers/files_controller.rb` | `resolve_sort`, ext filtering, flat mode, folder paths, bound + notice |
| `app/views/files/index.html.erb` | chip row + "or an extension" input; grid sort select |
| `app/views/files/_list.html.erb` | sortable headers, `aria-sort`, Folder column in flat mode |
| `app/views/files/_grid.html.erb` | (sort is applied upstream; no change beyond the shared control) |
| `app/views/files/show.html.erb` | attach dropdown + already-attached chips + conflict dialog render |
| `app/views/shared/_move_conflict.html.erb` | **new** — the collision `<dialog>`, rendered on two pages |
| `app/controllers/projects/attachments_controller.rb` | dedupe guard, auto-move, `#relocate` |
| `app/services/maker/move_node.rb` | **new** — the two-door move |
| `app/views/projects/show.html.erb` | render the shared conflict dialog |
| `config/routes.rb` | `POST /attachments`, `POST /projects/:project_id/attachments/relocate` |
| `app/assets/stylesheets/…` | chips, sortable headers, dialog |

No migration. No change to `FileLayer`, `Sync::*`, or any adapter.

---

## 8. Testing

Request-level tests, run on **all three legs** as this repo requires (`bin/rails test`,
`LIBRARY_BACKEND=share bin/rails test`, `LIBRARY_BACKEND=s3 bin/rails test`), each expected to stay
identical:

**Sorting**
- each key sorts as claimed, and `dir` reverses it
- the cookie persists the choice across a request with no params
- a junk `?sort=`/`?dir=` and a tampered cookie both fall back to the default
- directories stay grouped as they do today

**Type filter**
- single and multiple extensions; whole-library, ignoring `?folder=`
- an extension with no matches renders the empty state, not an error
- junk values (`../`, a 40-char string, a `%` LIKE metacharacter) are dropped, not queried
- directories never appear
- the Folder column shows the real path
- the bound: over 2000 matches renders the notice with the true total

**Attach + move**
- attaching an unattached file moves it into `Projects/<slug>/`; `node_id` is unchanged
- attaching a file already attached to another project does **not** move it
- attaching a file already in the folder is a no-op move
- attaching the same file to the same project twice creates one row
- a collision creates the attachment, moves nothing, and renders the conflict dialog
- `#relocate` moves with the new name and clears the prompt
- a `FileLayer::FetchError` during the move leaves the attachment and reports it
- the project page's existing picker gets the same behavior as the file page's dropdown

**`Maker::MoveNode`**
- unit tests per door: the port branch on share/s3, `Sync::Mutation` + broadcast on chunk

---

## 9. Invariants this respects

- **§10 (the maker/file-layer split):** nothing here touches sync, the changelog, conflicts, locks
  or the mounts. The move goes through the same two named doors `Maker::LibraryFolder` already
  uses, and the reason the `ext` column was rejected (§5.2) is precisely this line.
- **§15 (bytes out of Rails):** unchanged — nothing here moves bytes through Rails. A share-mode
  move is a `rename()`; a chunk-mode move is a metadata mutation.
- **One named mechanism (§9a-3):** capabilities are read through the `LibraryCapabilities`
  concern's `capabilities` helper, never inline off `FileLayer.current`; the move branch gets one
  home rather than a third copy.
</content>
