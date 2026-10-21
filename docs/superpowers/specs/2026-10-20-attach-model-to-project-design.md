# Attach a model to a project — design

2026-10-20. Branch `claude/zip-upload-and-model-attach`, shared with
`2026-10-20-zip-upload-unpacks-models-design.md` (independent; either can ship first). Facts cite
`main` at e14a589e.

The owner's request, verbatim: "Attach a model to a project".

Decisions taken with the owner before this was written:

| question | answer |
|---|---|
| What does attaching do? | Links — the model stays where it is; a model can be in several projects |
| Where can it be done from? | Both ends: the model (page and folder strip) and the project page |
| How does the project page show models? | A Models panel of model cards: linked models AND models living in the project's folder |
| How is the link stored? | The existing attachment rows — no new table |

## Today

- **Half of this exists.** `Maker::AttachToProject#call` on a file that a `Maker::Model` owns
  (`#model_owning`: the oldest `Maker::FileAttachment` row naming that node with
  `attachable_type: "Maker::Model"`) runs `#attach_bundle`: every live file of the model becomes a
  `Maker::FileAttachment` on the project, in one `insert_all`, and nothing moves. It is reached
  only by attaching one of the model's files from a file page or the Library inspector
  (`files/_attach.html.erb` → `Projects::AttachmentsController#create`).
- **Nothing on a model offers it.** `models/show.html.erb` and `files/_model_strip.html.erb` have
  no project control.
- **The project page shows the bundle as loose files.** `ProjectsController#show` puts attached
  files outside the project folder in `@linked_rows`, rendered as "Linked from elsewhere" in
  `projects/_attachments.html.erb`, one tile per file.
- **Models already live inside projects.** `Maker::ModelIntake::SHELVES` includes
  `Projects/*/models`, so each subfolder of a project's `models/` is a folder model and a lone
  model file there is a one-file model (`auto_node_id` is the file). The project page shows them
  only as the `models` folder panel's files.

## What the user sees

**On a model** — `models/show.html.erb` and `files/_model_strip.html.erb` (the strip a model's
folder opens with): an "In projects" row, built like `files/_attach.html.erb`. Chips for the
projects the model is linked to, each with a ×, and chips without a × for projects whose folder
holds the model. Then an **Attach to project ▾** dropdown of the user's other non-archived
projects, sorted by `FilesController#name_key`'s rule. Picking one attaches and returns to the
same page with "Attached <model> to <project>."

**On a project** — a new **Models** panel (`models`) of model cards (`models/_card.html.erb`:
square preview, title), ordered by title, each linking to the model:

- **Linked** models carry a **Detach** button.
- **In-folder** models carry none: they are the project's by where they are, and moving the folder
  out is what removes them. A model that is both shows once, as in-folder.

The panel head has **Add model**, which opens a picker at `/projects/:project_id/models/new?q=`:
the user's catalogued models matching the title query, or the 40 most recently updated with no
query, each with an Attach button. It is `Projects::AttachmentsController#new`'s page for models.
With no models the panel says "No models yet." beside the Add button.

The panel is a regular panel: on by default, hideable and placeable from the layout drawer like
any other (`Maker::ProjectKind`). It is not added to `ALWAYS`.

**"Linked from elsewhere" stops repeating them.** A linked row whose node belongs to a model shown
in the Models panel is left out of `@linked_rows`, so each file appears once — inside its model.

## How it is stored and read

**Attaching** is `Maker::AttachToProject#attach_model(model)` (new, public): `#attach_bundle(model)`
behind the same guards `#call` applies, so the file-page door and the model door cannot differ.
A model with no live files is refused (`:empty_model`) — "That model has no files to attach." — rather
than recorded as an attach of nothing.

**A project's models are derived on each render** (`Maker::ProjectModels.for(user, project,
attachments:)`, new, read-only):

1. **Linked:** for the project's live attached node ids, the models owning them by `#model_owning`'s
   rule — oldest `Maker::Model` row per node — in ONE query over `maker_file_attachments`, not one
   per node. The rule is shared with `Maker::AttachToProject`, not copied, so "which model owns this
   file" has one answer.
2. **In-folder:** catalogued models whose `folder_node_id` is a dir under the project's folder, or
   whose `auto_node_id` is a file under it. Ancestry comes from the library tree
   (`Maker::LibraryTree`), not from `Maker::ProjectFolderListing`, whose walk is capped at
   `FILE_CAP` files.

Both use the `catalogued` scope, so a dismissed auto model never shows. Bundles attached before
this ships appear as cards with no migration.

**Detaching** deletes this project's `Maker::FileAttachment` rows whose node is one of the model's
attached files — every row, live or tombstoned — and nothing else: no file moves, nothing is
deleted from the library, the model and its own rows are untouched. A row that was ALSO attached by
hand before the model owned it goes with the model, which is the same rule attaching uses.

**What the snapshot means.** A file added to the model after the attach gets no project row. The
card always opens the live model, so it is one click away; it is not in the project's own file
lists. Accepted with this design (the alternative was a new link table).

## Routes

- `POST /models/:model_id/projects` `{ project_id }` → attach. HTML only: redirects back with the
  notice (no caller wants JSON).
- `DELETE /models/:model_id/projects/:id` (`:id` is the project) → detach, redirect back with
  "Detached <model> from <project>."
- `GET /projects/:project_id/models/new?q=` → the picker.

`Models::ProjectsController` (new) and `Projects::ModelsController` (new, `new` only). Models
resolve by slug through `current_user.maker_models`, projects through `current_user.maker_projects`,
so another user's model or project is a 404 and never names anything of theirs. An archived
project is refused like the file attach dropdown refuses it. Redirects go back through `url_from`,
never to an absolute URL.

## Cost

`ProjectsController#show`'s query count is pinned constant in N by `page_query_budget_test.rb`, and
stays so: the derivation is a fixed number of queries whatever the number of models or files, and
the cards' cover thumbnails join the page's existing `Maker::Previews::ThumbnailMap.for` call
rather than making a second one. The model side's chips cost what `FilesController#attach_choices_for`
costs: two queries.

## Out of scope

- The public project page (`Maker::PublicProject`) keeps listing attached files as it does today.
- No "Attach to project" on the 3D models view's cards.
- Moving or copying a model into a project's folder — attaching never touches the disk.

## Tests

- **`Maker::ProjectModels`:** a model linked by bundle; a folder model in `models/`; a one-file
  model in `models/`; a model both linked and in-folder shows once as in-folder; a dismissed model
  excluded; a file owned by two models resolves to the older row; a model in another project's
  folder excluded.
- **`Maker::AttachToProject#attach_model`:** attaches every live file once, idempotent on repeat,
  refuses a model with no live files, never moves a node.
- **Controllers:** attach and detach round trip; detach removes only this project's rows for this
  model's files; another user's model/project → 404; an archived project refused; the picker's
  query filters by title and excludes dismissed models.
- **Project page:** linked model files no longer appear in "Linked from elsewhere"; the budget test
  extended with N linked and N in-folder models.
- **No system test:** attach, detach and the picker are plain forms with no Stimulus, so
  `test/system/README.md`'s rule keeps them at the request level (above), where the round trip —
  attach → card → Detach → files still in the library — is asserted.
