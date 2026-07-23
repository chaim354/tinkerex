# Design: Current Project (a session-scoped default destination for tools + uploads)

**Date:** 2026-07-23 · **Status:** DESIGN — awaiting spec review (no code yet)

## 1. Why

A maker working on one thing wants everything they make to land in that thing without
re-picking a destination every time. Today each save chooses a folder from scratch:
the Box Generator and Generators addons show a "Save to folder" dropdown that defaults
to the library root, and the Files page uploads to root. There is no notion of "the
project I'm working on right now."

This introduces a **current project**: a single selected project, shown in the top bar,
that becomes the default destination. When set, tool output and Files-page uploads
default to landing in that project's `Projects/<slug>` folder **and** being attached to
the project (so they appear on its page). It is a default, always overridable, and when
nothing is selected the app behaves exactly as it does today.

## 2. Decisions (settled in brainstorming — do not relitigate without new information)

1. **Session-scoped, not DB-persisted.** The selection lives in
   `session[:current_project_id]` (the project's integer id). It resets on sign-out and
   is per-browser-session, not shared across devices. (Chosen over a `users` column for
   simplicity; a DB-backed sticky version is out of scope, §8.)
2. **"Save in the current project" = folder + attach.** Output lands in the project's
   `Projects/<slug>` library folder **and** a `Maker::FileAttachment` is created tying it
   to the project. Both are needed: the project page lists *attachments*, not folder
   contents, so the folder alone would not make the file appear there.
3. **Scope = the /tools addons + the Files-page upload.** Box Generator, Generators, and
   any future addon (they share one save path), plus the Files browser's upload button.
   Not model (.zip) imports; not arbitrary other writes (§8).
4. **Two ways to set it:** a top-bar dropdown (also shows the current selection and
   switches/clears it) and a "Set as current" / "Clear" control on each project page.
5. **Files page keeps ONE upload button.** Its behavior switches on whether a project is
   current — it is not a second button. A small "to library root instead" link preserves
   loose uploads without having to clear the current project first.
6. **Tools attach BOTH output files** — the SVG output *and* the `params.json` — to the
   project.

## 3. Architecture

Everything is server-rendered Hotwire on the maker/session-auth side, consistent with the
rest of the web UI. **No new byte-write machinery**: this feature reads file metadata,
creates `FileAttachment` *references*, and reuses paths that already exist and are tested
(`Maker::Addons::LibraryOutput`, `Projects::UploadsController`,
`Projects::AttachmentsController`). It never touches sync, the changelog, conflicts,
locks, or the mounts — the file-layer split's §10 tripwire stays un-crossed.

### 3.1 `CurrentProject` controller concern

`app/controllers/concerns/current_project.rb`, included in `ApplicationController` so the
top bar (rendered in the layout on every page) can read it. Provides:

- **`current_project`** (`helper_method`, memoized) — resolves
  `session[:current_project_id]` via
  `current_user.maker_projects.where.not(status: "archived").find_by(id:)`. User-scoped,
  so a forged or foreign id resolves to `nil`; an archived or deleted project also
  resolves to `nil`. A `nil` result means "no current project" and every consumer falls
  back to today's behavior. (Archiving the current project therefore silently clears it.)
- **`current_project_folder_node_id`** — best-effort
  `current_project&.ensure_library_folder!(current_user)&.node_id`, rescuing to `nil`
  (`ensure_library_folder!` is idempotent; a `nil` return falls back to the library root
  rather than 500-ing a page).
- **`attach_addon_files_to_current_project(addon_files)`** — for the tools. Given the
  `Maker::AddonFile`s returned by `LibraryOutput.write`, and if a project is current,
  creates a `FileAttachment` per file (role via `FileAttachment.role_for(node.name)`).
  Attaches **all** of them (SVG + `params.json`). No-op when no project is current.
- **`current_project_choices`** (`helper_method`, memoized) — the active projects for the
  top-bar select: `current_user.maker_projects.where.not(status: "archived")
  .order(:name).pluck(:name, :id)`. One indexed query, only when signed in.

### 3.2 Route + controller (set / switch / clear)

```ruby
resource :current_project, only: %i[update destroy]   # singular; no id in the URL
```

`CurrentProjectController` (session-authed, like the rest of the web UI):

- **`#update`** — sets `session[:current_project_id]` from `params[:project_id]`, scoped
  to `current_user.maker_projects` (an unknown/foreign id is ignored, not stored). A
  **blank `project_id` clears** the selection, so the top-bar "— none —" option flows
  through the same action. `redirect_back fallback_location: files_path`.
- **`#destroy`** — clears `session[:current_project_id]` (the explicit "Clear"/"×").
  `redirect_back fallback_location: files_path`.

### 3.3 Top bar (`layouts/application.html.erb`)

A compact inline form in the existing `header.topbar`, shown when signed in:

```
Project: [ ▾ current project (or “— none —”) ]
```

A `form_with url: current_project_path, method: :patch, data: { turbo: false }` wrapping a
`select_tag :project_id` built from `current_project_choices` with the current one
selected and a leading blank "— none —" option; `onchange: "this.form.requestSubmit()"`.
`turbo: false` → a normal submit + redirect + full reload, so the bar (and any
project-dependent defaults) update everywhere. This both **displays** the current project
and is the primary **switcher**.

### 3.4 Project page (`projects/show`, in `head-actions`)

- If `current_project == @project`: a "★ Current project" label + a "Clear" button
  (`button_to current_project_path, method: :delete`).
- Otherwise: a "Set as current" button
  (`button_to current_project_path, method: :patch, params: { project_id: @project.id }`).

### 3.5 Tools (Box Generator, Generators)

Both controllers already use the `Tools::LibraryFolders` concern and render a
`select_tag :parent_node_id, options_for_select(@folders)`.

- **Default the picker** to the current project's folder: pass a selected value into
  `options_for_select(@folders, current_project_folder_node_id)`. The controller ensures
  that folder exists (so it is a real option in `@folders`) when a project is current.
  The user can still choose any other folder — this only changes the default.
- **Attach after save:** `LibraryOutput.write` already returns the created `AddonFile`s
  (the controllers currently discard that return) — capture it and feed those `AddonFile`s
  to `attach_addon_files_to_current_project`. Both files (SVG + `params.json`) become
  `FileAttachment`s on the current project. No current project ⇒ unchanged (root default,
  no attach).

### 3.6 Files page upload (`files/index`, Approach A — reuse the project path)

The "upload into a project folder + attach" flow already exists generically as the
`projects/_upload_control` partial driven by `uploader_controller.js` /
`Projects::UploadsController` / `Projects::AttachmentsController`, parameterized by
`upload_url` / `attach_url` / `parent_node_id` / `redirect_url`. The Files page reuses it:

- **Current project set:** render `projects/_upload_control` with
  `upload_url: project_uploads_path(current_project)`,
  `attach_url: project_attachments_path(current_project)`,
  `parent_node_id: current_project_folder_node_id`,
  `redirect_url: files_path`. The single upload button now lands the file in the project
  folder and attaches it, on all three backends — no new controller or JS. A small
  "upload to library root instead" link renders the today's-behavior upload as an
  override (a link, not a second primary button — decision §2.5).
- **No current project:** the existing plain upload block, exactly as today.

## 4. Components (new / touched)

| Component | Path | Change |
|---|---|---|
| `CurrentProject` concern | `app/controllers/concerns/current_project.rb` | **new** — helpers above |
| `CurrentProjectController` | `app/controllers/current_project_controller.rb` | **new** — `update`/`destroy` |
| Route | `config/routes.rb` | **new** — `resource :current_project` |
| Application controller | `app/controllers/application_controller.rb` | include the concern |
| Layout top bar | `app/views/layouts/application.html.erb` | project dropdown |
| Project show | `app/views/projects/show.html.erb` | set/clear control |
| Boxes controller + `new` view | `app/controllers/tools/boxes_controller.rb`, `app/views/tools/boxes/new.html.erb` | picker default + attach |
| Generators controller + `index` view | `app/controllers/tools/generators_controller.rb`, `app/views/tools/generators/index.html.erb` | picker default + attach |
| Files index | `app/views/files/index.html.erb` | project-aimed upload control + override link |

No model, migration, or JS changes. (The current project is session state; attaches reuse
`Maker::FileAttachment`; uploads reuse `uploader_controller.js` unchanged.)

## 5. Data flow

1. **Select:** user picks a project in the top bar (or clicks "Set as current" on a
   project) → `PATCH /current_project` → `session[:current_project_id]` set → redirect
   back → top bar shows the name; defaults now point at it.
2. **Tool save:** the "Save to folder" picker is pre-selected to `Projects/<slug>` →
   `LibraryOutput.write` lands the SVG + `params.json` in that folder →
   `attach_addon_files_to_current_project` creates two `FileAttachment`s → both appear on
   the project page.
3. **Files upload:** the upload button drives the existing project upload/attach flow into
   `Projects/<slug>` → file appears on the project page.
4. **Clear / sign out:** `DELETE /current_project` or session end → `current_project` is
   `nil` → tools default to root, Files upload is the plain root upload — today's
   behavior, no regression.

## 6. Error handling & safety

- **User-scoping / stale ids.** `current_project` only ever resolves within
  `current_user.maker_projects`; a forged, foreign, archived, or deleted id → `nil` →
  graceful fallback. `#update` refuses to store an id that is not the user's own project.
- **Folder creation is best-effort.** `current_project_folder_node_id` rescues to `nil`
  (falls back to root); no page 500s if the backend is briefly unreachable.
- **Zero-regression when unset.** Every consumer branches on `current_project` and, when
  `nil`, does exactly what it does today.
- **§10 boundary.** Reads metadata + creates `FileAttachment` references + reuses existing
  write paths only. No sync/changelog/conflict/lock/mount surface is touched. Attaching
  moves no bytes.
- **Backend-neutral.** `FileAttachment` and the folder node are maker-side and
  backend-agnostic; the actual byte writes reuse the per-backend paths
  (`LibraryOutput` for tools; `Projects::UploadsController` + `uploader_controller.js` for
  uploads) that are already green on chunk / share / s3.

## 7. Testing

- **`CurrentProjectController`:** `update` sets the session; a blank `project_id` clears;
  a foreign/unknown id is ignored (nothing stored); `destroy` clears; both redirect back.
- **`current_project` helper:** returns `nil` for unset / foreign / archived / deleted.
- **Tools (`Boxes` + `Generators`) `#create`:** with a current project → both files land
  under `Projects/<slug>` and two `FileAttachment`s exist on the project; without → root,
  no attachments. The `new`/`index` view pre-selects the project folder in the picker.
- **Files `index`:** with a current project → the upload control targets
  `project_uploads_path` / `project_attachments_path` and the "library root" override link
  renders; without → the plain upload block.
- **Top bar:** renders `Project: <name>` with the current option selected; lists active
  projects; shows "— none —" when unset.
- Runs on the existing **chunk / share / s3** CI legs (the attach + folder logic is
  backend-neutral; byte writes reuse tested paths).

## 8. Explicitly out of scope (YAGNI)

- DB-persisted / cross-device / cross-session current project (a `users` column). This is
  session-only by decision §2.1.
- Routing Model (.zip) imports to the current project.
- Changing how Files-browser folder navigation interacts with uploads (uploads still ignore
  the currently-viewed folder, as today; the current project — not the viewed folder — is
  the default target).
- Auto-attaching writes outside the two named surfaces (tools + Files-page upload).
- A dedicated project-switcher page or modal — the top-bar dropdown suffices.

## 9. Suggested phasing (for the implementation plan)

Each phase is independently shippable and testable:

1. **State + surface it.** The `CurrentProject` concern, route, `CurrentProjectController`,
   top-bar dropdown, and the project-page set/clear control. Delivers the visible
   "current project" concept end-to-end.
2. **Tools default to it.** Picker default + attach-both-files in Boxes and Generators.
3. **Files upload defaults to it.** The project-aimed upload control + override link on the
   Files page.
