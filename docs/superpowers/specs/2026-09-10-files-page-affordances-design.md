# The Files page's missing affordances — design

Date: 2026-09-10. Branch: `claude/files-affordances`. Base: `146f8771` (main, after the UI-cohesion
sweep's slices 0–4). Status: **design approved, unimplemented.**

Four things a maker asked for, in one spec because they meet in two places: the right-click menu has
to learn about folders before it can delete one, and the editor has to learn about files outside a
repository before it can open one it just created.

- **A. The repo browser's Back control is inert at the top level** and still renders as a live button.
- **B. The right-click menu has no Delete**, and does not appear on folders at all.
- **C. There is no way to create a text file**, and the built-in editor refuses anything outside a
  git repository.
- **D. A folder cannot be deleted** on share or s3 — the button is there and answers 422.

## 0. What was measured, and where the surprises were

Read on `146f8771`, not assumed. Two of the four are not what they look like from the outside:

**D is not missing UI.** `FilesController#destroy` (`files_controller.rb:970`) already hands a
directory to the port, and its own comment says so: *"The Delete button IS rendered for
directories, so this is the ordinary path, not an edge."* What refuses is the adapter —
`dir_deletable: false` on `share.rb:33` and `s3.rb:89`, `true` on `chunk_remote.rb:56` — and the
refusal arrives as `UnsupportedOperation`, which the controller maps to 422. So the work is entirely
below the controller.

**A is a control that looks available and does nothing.** `lib/file_chooser.js` writes
`← Back` into *both* faces' markup (`:100` inline, `:147` modal), and `back()` opens with
`if (this.trail.length === 0) return` (`:297`). At the root of a repository the button is styled
live, focusable, and inert. That is the shape `§14d` records for an unresolvable Stimulus
identifier — no error, no warning, the behaviour is simply absent — with the added cost that here
the user can *see* the control.

**C already has most of its machinery and one explicit prohibition.** `Maker::TextSave.call` takes
`node:` as nilable (it has a create branch) and `repo_root_node_id:` defaults to nil, recording a
pending git edit only `if repo_root_node_id.present? && local_worktree?`. So the service does not
need widening. What refuses is the *door*: `FilesController#update` (`:643-646`) returns
*"Only files inside a git repository can be edited."* And `docs/invariants/git-editing.md` names
this exact request and forbids doing it the cheap way:

> D3's fuller wording ("Markdown is editable anywhere", story 2.13) is **not** implemented: widening
> `FilesController#update` to any `.md` outside a repository is a second door with its own surfaces
> — the file page's editor, its own no-history note, its stale thumbnail — and **needs its own spec
> and its own slice**. Do not widen this one to get there.

This is that spec.

**B is a helper with a stated boundary.** `FilesHelper#file_menu_data` (`files_helper.rb:40`) carries
`note_url`, `download_url`, `addon_open_url`, `addon_open_label` — no delete — and its sibling's
comment states the two are not co-extensive because *"a folder gets NEITHER"*.

**One correction to the user's own framing, recorded because the next reader will repeat it.** The
first reading of "the file partial always says back" pointed at `files/show.html.erb:46`, which
renders a literal `"Back"` through `back_target_path(default: files_path)`. That is a *different*
control and it is working as designed — §14d explains why it takes the referer rather than a param.
The complaint is the **project page's** repo browser (`projects/_repo_browser.html.erb`), which
mounts `lib/file_chooser.js` in browse mode. `files/show.html.erb` is out of scope here.

## 1. Decisions

1. **Fix the shared module once, in `render()`, not in the two markup templates.** Both faces of the
   chooser are drawn from the same class; a fix in one template is a fix for one caller.
2. **The editor's rule outside a repository is `capabilities.versioned?`, not an extension list.**
   Any file the app already classifies as text becomes editable, and share/s3 carry the no-history
   note. This is the trade the README door already made and *names on the editor*; a second rule
   here would be a second vocabulary to keep in step (§14d's standing complaint).
3. **A name-minting door asks BOTH questions.** `Maker::MoveNode.valid_leaf_name?` for syntax and
   `Library::ReservedNames.reserved?` for the library's own namespace. §14b records the upload door
   shipping with **neither** and being the weakest door in the app; the new-file door is a fourth
   such door and must not repeat it.
4. **`dir_deletable` is DELETED, not left constant-true.** Once all three backends cascade, a
   capability nothing varies is a lie about the shape of the port. §14a's own warning is that
   agreement across three backends is three samples rather than an identity — but here there is no
   counterexample left to protect. Its §14a bullet becomes a note about why directories used to be
   refused.
5. **s3's folder delete is capped, and the cap refuses rather than half-completing.** Count
   descendants first; delete synchronously under the cap, refuse above it with a message naming the
   count. A background job is explicit follow-on work, not smuggled in here: a job that fails halfway
   has to decide what the catalog says meanwhile, which is §14a's landmine spread across time.
6. **No new page-level CSS.** The chooser's classes are already `components.css`'s
   (`design-system.md` rule 3); the menu is built in JS from existing classes.

## 2. A — the Back control disappears at the top level

`render()` sets the control's `hidden` on `trail.length === 0`. `el.hidden`, not `style.display` —
the house idiom, already used by `readme_controller.js:91` and twice in
`layout_editor_controller.js`, so the chooser does not introduce a second way to hide a control.

Nothing else about the chooser changes. The crumbs beside it already say where you are and are the
real navigation; Back is the convenience, and a convenience that cannot act should not be offered.

**Guard.** A system test, because only a browser knows whether a control is visible: mount the repo
browser at a repository's root, assert no visible Back; descend one folder, assert Back is visible
and returns; assert the crumbs render at both depths so the test is not passing over an unmounted
component. **Mutation:** remove the `hidden` assignment and confirm the root assertion reddens.

## 3. B — Delete on the right-click menu, and the menu on folders

`file_menu_data` gains `delete_url` (`file_path(node_id)`, the same target the list row's
`button_to` already uses). `filemenu_controller.js` gains a Delete item that:

- **issues a real `DELETE` with the CSRF token**, not a link — the menu is built in JS, so it
  assembles a form or sends `X-CSRF-Token` explicitly;
- **confirms first**, with the wording the existing buttons use (`Delete <name>?`), so the three
  delete doors agree;
- **renders last**, after the addon item, and is the only destructive item in the menu.

**Folders get the menu.** `file_menu_data` is currently withheld from a folder, so today there is
nothing to right-click. A folder's menu holds Delete alone: it has no note popover, no blob to
download, and no addon origin. That makes the helper's "not co-extensive" comment more true rather
than less — a folder gets the menu and no thumb cell.

**AND IT IS GATED ON `dir_deletable?` UNTIL PART D LANDS (added 2026-09-10 during implementation).**
This spec originally shipped the folder menu in slice 1 and the working delete in slices 3–4, on the
reasoning that the menu and the port are different concerns. They are — but a Delete that cannot
delete is the same defect part A removes from the Back control, and driving it settled the question:
a folder DELETE on share answers 302 with the flash `"<uuid>" is a dir: share-mode delete is files
only — deleting a directory would strand its children's nodes …`. An internal sentence with a raw
node id, in front of a maker. `folder_menu_data` therefore returns `{}` unless the backend can
cascade, which is the one question `dir_deletable` exists to answer — so **chunk_remote, the primary
deployment, gets folder delete in slice 1** and the other two get it with part D, at which point the
capability and this branch are removed together.

**Guard.** Request-level for the payload (`delete_url` present on a file row and on a folder row);
system-level for the menu actually deleting, since the JS-built form is the half no request test can
see. **Mutation:** drop `delete_url` from the helper and confirm both reddens.

## 4. C — a text file, created and edited outside a repository

**Creating.** `Files::TextFilesController#new` and `#create`, a door of its own rather than a
parameter on `FilesController#create` — the upload door has one job and a batch-of-uploads branch
already (`files_controller.rb:777-800`), and a create-empty-file riding it would need a third arm
that takes no bytes. `#create` writes an empty file through the port at the current folder and
redirects to the file page with the editor open.

The name is validated by decision 3's two guards, and the folder is the one the user is looking at
(`parent_node_id`, as the upload door takes it).

**Editing.** `FilesController#show`'s `@editable` (`:507`) currently reads
`@kind == :text && @repo_root.present? && editable?(node)`. The `@repo_root.present?` term goes.
`#update`'s refusal (`:646`) goes with it. What replaces both is the README door's shape:

- the no-history note renders when `capabilities.versioned?` is false — *"This library keeps no
  history for this file; saving replaces it."* — and not at all on chunk_remote;
- `Maker::TextSave` is called with `repo_root_node_id:` still resolved from
  `Library::WorkingTree#root_for`, which is **nil outside a repo and unchanged inside one**. That is
  the whole of how a file in a repository keeps its pending-edit behaviour while a file outside one
  gets none. No branch is needed in the door.

**What still holds, and breaks if undone** — inherited from `git-editing.md`, restated because this
door is new and inherits none of it by accident:

- bytes go through the port (`TextSave` → `LibraryOutput.write_bytes!` → `FileLayer#write`), never
  `File.write` and never delete-then-create, both of which orphan every attachment, BOM line and tag
  silently;
- **`replace: true`, so the node survives** and stays attachable and taggable;
- the `base_token` stale check still refuses a save whose content moved underneath it;
- a `.lock` is still refused and never deleted — this door has no git path, so it inherits the
  refusal by not having one to skip;
- the 200,000-byte cap is still the **server's**, read from `FilesController::EDITABLE_MAX_BYTES`;
- **restore stays git-only.** There is no undo on this door, which is exactly what the note says.

**Guard.** Request-level: create refuses a reserved name and a bad leaf name; the editor renders for
a text file outside a repo; a save round-trips and the node id survives it. System-level: the
no-history note is present on share and **absent on chunk_remote** — a note that renders everywhere
is the same defect as one that renders nowhere, and only the rendered page can say which.
**Mutation:** restore `@repo_root.present?` and confirm the editor-renders assertion reddens.

## 5. D — a folder delete on every backend

### share — one rename

`Share#delete` on a directory renames it whole into `.trash/<node_id>/<name>` — the layout §14a
already defines, keyed by `node_id` so two same-named deletes cannot collide — then tombstones the
directory **and every descendant node** in one transaction.

Order is **move-then-tombstone**, the same way the file path already works and for the same reason:
the reverse fails *silently*, because the next scan observes bytes still at the old path and
`Reconciler#create_or_revive!` revives the tombstone.

**The subtree tombstone is the correctness half, not bookkeeping.** A live node pointing at a path
now inside `.trash` is §14b's skip-list wedge: the scan refuses to look in `.trash`, so the node can
never be paired, and the resulting tombstone trips the mass-deletion guard — **refusing that scan and
every scan after it, permanently**. §14b lists four instances of this and says to assume every path
that writes is exposed until checked.

`Share#undelete` reverses it: rename back, revive the subtree. §14a's existing rule that an orphaned
restore is **refused** rather than reparented to the root already covers restoring a child before its
parent, and it applies unchanged — the refusal is recoverable, a scatter is not.

### s3 — copy every object, then delete every object, then tombstone

There is no directory and no rename, so a folder is a key prefix. For each object under it: copy to
`.trash/<node_id>/<relative path>`, and only once **every** copy has confirmed, delete the sources;
only once every delete has confirmed, tombstone the subtree.

**That order is the whole design.** §14a's landmine is a delete failing *after* a tombstone: the next
scan finds an unclaimed key with no tombstone to revive by path, mints a **new `node_id`**, and
orphans every attachment — by a scan that did nothing wrong, with no error anywhere. A failure at any
stage leaves the catalog untouched and reports; nothing is half-done.

**The cap.** Count descendants first. Under the cap, delete synchronously. Over it, refuse with a
message naming the count, because a folder of 5,000 objects is 10,000 billed requests and will
exhaust the request before it exhausts the folder. Initial cap **500 objects**, a constant with its
reasoning beside it, not a literal at the call site.

Per-segment encoding uses `ERB::Util.url_encode`, never `CGI.escape` — §14e records `FakeS3` sharing
the adapter's inverse-encoding misunderstanding and hiding **silent permanent data loss on any
filename with a space** behind 79/80 green tests. The fake must be asserted against the **wire
format**.

### the capability goes

`dir_deletable` is removed from `Capabilities`, from all three adapters, and from
`adapter_mutation_contract.rb`'s gate (it gates three places there — `:31`, `:43`, `:173`).
`FilesController#destroy` stops branching. §14a's bullet is rewritten as a note recording why
directories were refused until 2026-09-10 and what each backend now does instead.

**Two tests name the capability in their own titles** and must be renamed with it rather than left
describing a constant that no longer exists: `chunk_remote_journey_test.rb:166` (*"a directory delete
cascades, because dir_deletable is true on chunk_remote"*) and its assertion message at `:204`. A
test whose name explains a deleted concept is the stale-ledger problem §15 records, in a place no
gate reads.

**Guard.** The shared adapter mutation contract gains a directory-delete case, so all three backends
answer it — that is the point of the contract, and it is where the s3/share asymmetry would otherwise
hide. Plus: a share delete of a nested folder leaves **no live node** under `.trash` (the wedge), an
s3 delete over the cap refuses and **writes nothing**, and a restore returns the subtree with the
**same node ids** — which is what every attachment is keyed on. **Mutations:** tombstone only the
directory and confirm the wedge guard reddens; tombstone before moving and confirm the revive
assertion reddens.

## 6. Slices

Each independently shippable and revertible, ordered so the cheap corrections land first.

1. **A + B** — the Back control, `delete_url`, Delete in the menu, the menu on folders. No port
   changes; two guards.
2. **C** — the text-file door and the editor outside a repository.
3. **D share** — the rename, the subtree tombstone, undelete, and the contract case.
4. **D s3** — the copy/delete/tombstone sequence, the cap, and removing `dir_deletable`.

Slice 4 removes the capability because it is the last backend to gain the behaviour; doing it earlier
would leave the port claiming something one adapter could not do.

## 7. Testing

Bare `bin/ci` per slice — all seven gates, three backend legs at identical run counts (§15). Slice 3
and 4 touch the port, so `test-chunk-remote` matters most there: it is the only leg exercising the
backend the primary deployment runs.

Every guard is mutation-checked, with the mutation and its actual output named in the PR. The
`.to_i`-style trap is live in slice 3: a tombstone test comparing timestamps at second resolution
cannot fail, so assert a **content** column that is nil until something writes it, or separate the
events with `travel_to`.

## 8. Risks

- **The s3 sequence is the highest-risk code in this spec.** It is the one path that can orphan
  attachments silently, and its failure mode is invisible until someone opens a project and finds its
  files gone. The contract case and the wire-format assertion are what stand between it and §14e's
  79/80-green precedent.
- **Widening the editor widens what a save can destroy.** Outside a repository there is no undo, and
  the only thing standing between a maker and a lost file is a sentence on the editor. That sentence
  is load-bearing and must not be dropped in a restyle.
- **Deleting `dir_deletable` is irreversible cheaply.** If a fourth backend ever cannot cascade, the
  capability has to come back. That is the right trade — §14a's rule is that a capability earns its
  place by varying — but it is a trade.
- **The cap will be hit.** 500 objects is not a large folder for a maker with a print library, so the
  refusal message is a real user-facing surface, not a corner. The background job that lifts it is
  named follow-on work.
