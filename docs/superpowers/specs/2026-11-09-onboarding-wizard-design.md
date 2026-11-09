# Onboarding wizard: two tracks to a first project

**Date:** 2026-11-09 · **Status:** approved design, not yet built · **Branch:** `claude/onboarding-wizard`

## Goal

A new account is walked once through what Tinkerex does and ends on its first real project with
real files in it. The walk has two tracks, because the two ways people use Tinkerex want different
things explained:

- **Organize my files** — laser, CNC, electronics, documents. The point is the library, previews,
  Measure, and projects that file themselves.
- **Organize my 3D models** — STL, 3MF, STEP, prints. The point is the model catalog, the 3D viewer
  and the print log.

## What this builds on

The 2026-10-13 onboarding work (`docs/superpowers/specs/2026-10-13-f-onboarding-design.md`) stays as
it is: the per-backend empty states, Recent's Getting started panel, and `/help`. That spec put
per-user onboarding state out of scope; this one adds exactly one column of it (`users.onboarded_at`)
and nothing else. The wizard reuses `shared/_where_files_come_from` for every sentence about where
files come from on this backend, so there is still one copy of those claims.

## The flow

Five steps, shared by both tracks. A step rail at the top of every page reads
**Choose · Tour · Project · Files · Done** and marks the current one. Back and Next are real links;
the only JavaScript is what the upload controls already use.

### 1. Choose — `GET /welcome`

"What will you mostly use Tinkerex for?" Two equal cards, each a link:

- **Organize my files** — "Laser, CNC, electronics and documents" → `/welcome/files/tour`
- **Organize my 3D models** — "STL, 3MF, STEP and prints" → `/welcome/models/tour`

Below them, a quiet **Skip for now** (`POST /welcome/skip`). The choice is not stored; it lives in
the URL from here on. No accent on this page: the two cards are equal and neither is the default.

### 2. Tour — `GET /welcome/:track/tour`

Four or five feature cards. Each has a title, one or two sentences, and where to find the feature
in the app. Cards with a matching landing screenshot show it (`landing/viewer.jpg`,
`landing/measure.jpg`, `landing/project.jpg`, `landing/boxes.jpg`). `landing/library.jpg` is not used:
it is untracked work in the owner's checkout.

**Files track**
1. **Your library is a folder.** The backend sentence from `shared/_where_files_come_from`
   (`projects: false, sources: true`).
2. **Previews for what you make.** SVG, DXF, PDF, LightBurn, Gerber, images and code open in the
   browser. (`landing/viewer.jpg`)
3. **Measure and print at true scale.** Measure a part's outline and print it 1:1. (`landing/measure.jpg`)
4. **Projects that file themselves.** A folder under `Projects/` is a project, and files you drop at
   its root are sorted into type folders. The folder names are set in Settings → Shelves. (`landing/project.jpg`)
5. **Tools that make files.** The Box Generator, Labels, Cut List and the other Tools save SVG
   straight into the library. (`landing/boxes.jpg`)

**3D track**
1. **Models find themselves.** Every STL, 3MF and STEP in `Models/`, in a project's `models/` folder,
   or anywhere on a shelf becomes a model in 3D models, with no tagging.
2. **A 3D viewer in the browser.** Turn a model around and look at it without opening a slicer.
   (`landing/viewer.jpg`)
3. **A print log.** Record each print of a model: the printer, the material, and whether it worked.
4. **Import from Printables.** Upload a downloaded zip; it unpacks into a model folder.
5. **Tools that make printable parts.** Gridfinity Bins, Simple Parts, Lithophane and OpenSCAD save
   STL or 3MF into the library. No screenshot: `landing/boxes.jpg` shows a laser-cut box.

The final sentences are written during implementation against the real pages, and each one must
be true on all three backends, as the 2026-10-13 spec's copy had to be. **Next** (the accent) goes to
the project step; **Back** goes to Choose; **Skip for now** is on every step.

### 3. Project — `GET` and `POST /welcome/:track/project`

A small form: **Name** (required) and **Description** (optional).

- **Files track:** a kind picker with Laser cutting, CNC, Electronics & firmware, Mixed and Other
  (`Maker::Project::KINDS` minus `print`). The kind sets the project page's panel layout
  (`Maker::ProjectKind`). Default: Mixed.
- **3D track:** no picker. The kind is `print` and the page says so: "This will be a 3D printing
  project."

A line under the form says the other way in: a folder you drop into `Projects/` becomes a project
on its own. **Create project** is the accent.

The POST goes through the same creation path as New project (see "Creating the project" below). On
success it records the wizard as done (`onboarded_at`, if still empty) and redirects to the files
step with `?project=<slug>`. On a validation error it re-renders this step with 422 and the model's
errors, the way `projects#new` does.

### 4. Files — `GET /welcome/:track/files?project=<slug>`

The page points the top bar's **Upload** at the project folder and makes it the page's one accent
(`use_folder_destination(project.folder_node_id, path:, primary: true)`). There is no second upload
control on the page; the copy points up at the top bar, as Recent's Getting started panel does.

It says what will happen:

- **Files track:** "Drop files at the project's root and they are filed into type folders: SVG and
  DXF into `design/`, LightBurn into `laser/`, and so on." The folder names are read from the
  same source the filing sweep uses (`Maker::ProjectFolders` plus the user's filing rules), not
  written into the copy, so a renamed shelf shows its new name.
- **3D track:** "STL and 3MF files go into `models/`, and each becomes a model in 3D models."

Then the backend's other ways in, from `shared/_where_files_come_from` (`projects: false`): copy into
the share, or into the desktop app's folder. A quiet **I'll add files later** link goes to the Done
step.

If the project's folder could not be made (`folder_node_id` is nil), the page says the folder is not
there yet, shows the same sentence the project page's alert uses, and offers only **Try again**
(reload) and **I'll add files later**. Upload falls back to its folder chooser because no destination
is set.

### 5. Done — `GET /welcome/:track/done?project=<slug>`

"<Project> is ready." Then what landed: the project's file attachments, grouped by the folder each
one is filed in, each drawn with the project page's file tile (`projects/_file_tile`), so thumbnails
fill in through the existing polling. With no attachments yet: "No files yet. Anything you add to
`Projects/<slug>` is filed into this project."

Buttons:
- **Open <project>** — the accent, `project_path`.
- **Go to 3D models** (3D track) or **Go to Library** (files track) — quiet.

**3D track only:** rendering this step enqueues `Maker::ModelIntakeJob.perform_later(user_id:)`.
Without it, on share and s3 an uploaded STL waits for the next 15-minute `Library::ScanJob` before it
appears in 3D models. The job is safe here: the upload's filing sweep ran before the redirect, so the
files are already under `models/` (`model-intake.md`: the catalog must run after the intake). The job
is already limited to one per user with duplicates discarded, so a reload costs nothing. Each STL
tile links to its file page, which has the 3D viewer. It does not link to a model page, because the
model may not have been catalogued yet when the page renders.

There is no "finish" request: reaching Done needs a project, and creating it already recorded the
wizard as done.

## When it opens, and what records it as done

- **One column:** `users.onboarded_at`, a nullable datetime. The migration sets it to the migration
  time for every existing user, so nobody already using the app is sent to the wizard.
- **Opens by itself in one place:** `HomeController#index` redirects to `/welcome` when
  `current_user.onboarded_at` is nil and the user is not the demo account
  (`Tinkerex::Demo.demo?`). Sign-in already lands on Recent (`after_sign_in_path_for` → `root_path`),
  so this covers the first sign-in. It is not a `before_action` anywhere else: a link from another
  page to a file works on a new account.
- **Recorded as done** (only if still nil, so the first time is kept) by:
  - `POST /welcome/skip`, which then redirects to Recent;
  - a successful `POST /welcome/:track/project`.
  Closing the tab partway through the tour leaves it nil, and the wizard opens again on the next
  visit to Recent. That is deliberate: they have seen nothing yet.
- **Open again on demand:** a **Take the tour** link in Recent's Getting started panel and near the
  top of `/help`. A finished user can walk it again; the project step then creates another project,
  which is what they asked for. It never opens by itself again.

## Routes and controller

`WelcomeController`, session-authed like every web controller, normal app layout (rail and top bar
stay):

```
GET  /welcome                            welcome#choose
POST /welcome/skip                       welcome#skip
GET  /welcome/:track/tour                welcome#tour
GET  /welcome/:track/project             welcome#new_project
POST /welcome/:track/project             welcome#create_project
GET  /welcome/:track/files               welcome#files     (?project=<slug>)
GET  /welcome/:track/done                welcome#done      (?project=<slug>)
```

- `track` is constrained to `files|models` in the routes, so anything else is a 404 before the
  controller runs.
- `?project=` is looked up with `current_user.maker_projects.find_by!(slug:)`; another user's slug,
  or a missing one, is a 404.
- `ShellHelper::SECTIONS["home"]` gains `welcome`, so the pages light Recent (design-system rule 8).
- New styles (step rail, choice cards, tour cards) go in `components.css`, inside the existing
  `@layer` order, as `docs/invariants/design-system.md` requires. No component selector is defined
  anywhere else. Each page has at most one accent (rule 13), as listed per step above.

## Creating the project

`ProjectsController#create` builds and saves the project, then calls its private
`ensure_project_folder`, and builds the notice and alert with `created_notice` and
`folder_failure_alert`. The wizard needs the same steps and the same sentences. Rather than copy
them, extract **`Maker::CreateProject`** (§14d: a verb more than one controller performs gets a named
service):

```ruby
result = Maker::CreateProject.call(user, attributes)
result.project   # the Maker::Project, persisted or not
result.created?  # saved
result.notice    # "Created X. Its folder is Projects/slug." / "Created X."
result.alert     # nil, or the unreachable / refused sentence
```

It saves, ensures the folder, and turns a folder failure into the alert, logging the class and
message as `ensure_project_folder` does now. `ProjectsController#create` keeps its demo-publish check
in front (`demo_may_publish?`) and calls the service; its behavior and copy do not change, and its
existing tests stay as they are. `WelcomeController#create_project` calls the same service with
`kind:` forced to `print` on the 3D track, and permits only `name`, `description` and (files track)
`kind`.

## Getting back to the wizard after an upload

Upload has two flows, and both need to land on the Done step.

- **share / s3 (`port_writable?`):** the top bar's form posts to `files#create`. The files step adds a
  hidden `return_to` field set to `welcome_files` or `welcome_models`. `files#create`'s HTML branch,
  single and batch alike, redirects to the Done step when `return_to` is one of those two values and
  the upload's `parent_node_id` is the folder of one of the user's projects
  (`current_user.maker_projects.find_by(folder_node_id:)`). Otherwise it redirects as it does today.
  The flag is allowlisted, never a URL, the same pattern as the `return_to` values rename and move
  accept. The notice from the upload carries over in the flash.
- **chunk_remote:** the top bar renders the presigned `uploader` controller, which already has a
  `redirectUrl` value it navigates to after a clean run. The files step sets it to the Done step's
  path.

Both are passed to `layouts/_topbar_upload` through one new helper, `upload_return`, set only by
`WelcomeController#files`. It is nil on every other page, so the partial's output elsewhere does not
change. A zip dropped on Upload still goes to its unpack page; the wizard does not follow it there.

## Errors

| Case | What happens |
|---|---|
| Unknown track | 404 (route constraint) |
| `?project=` not the user's, or missing | 404 |
| Name blank or taken | Project step re-renders, 422, model errors shown |
| Folder could not be made | Project still created; the files step shows the folder-pending state above, with the same sentence as the project alert |
| Upload refused (name taken, reserved name) | Handled as today: the existing alert, back on the files step. Only an upload that landed at least one file goes to Done |
| Library unreachable during upload | The existing 503 handling; nothing new |
| Demo account | Never redirected to the wizard; can open it from the link like anyone |

## Testing

**Request tests** (`test/integration/web/welcome_test.rb`):
- Recent redirects to `/welcome` for a user with `onboarded_at` nil; does not for a done user; does
  not for the demo account.
- Skip sets `onboarded_at` and redirects to Recent; a second skip keeps the first timestamp.
- Create project sets `onboarded_at`, makes the project and its folder, and redirects to the files
  step. The 3D track saves kind `print` even when the request sends another kind. A blank name is 422
  and creates nothing.
- Unknown track 404s; another user's project slug 404s on files and done.
- The files step renders the top bar upload aimed at the project folder, with the return wiring
  asserted per flow. **This assertion branches on `port_writable?`**: the hidden `return_to` on share
  and s3, the uploader's redirect value on chunk_remote. A form-shaped assertion is red on the
  chunk_remote leg.
- `files#create` with `return_to=welcome_models` and a project-folder parent redirects to Done;
  with a parent that is no project's folder, or an unknown `return_to`, it redirects as before.
  share/s3 only, since it drives `files#create`, the way the existing upload tests are gated.
- The 3D Done step enqueues `Maker::ModelIntakeJob`; the files Done step does not.
- Project-folder fixtures are made port-free (`project_folder_rows!`) wherever the test is not about
  creating the folder.

**Migration:** existing users get `onboarded_at` set; a user created afterwards has it nil.

**System tests** (`test/system/onboarding_test.rb`), on the system gate's backend: the files track
uploads an SVG and sees it on Done under its type folder; the 3D track uploads an STL and sees it
under `models/`.

**`Maker::CreateProject`:** a service test for the notice and both alerts. The existing
`projects#create` tests pass unchanged, which is the check that the extraction kept behavior.

**Mutation checks** (break, see red, restore): the demo exclusion, the `onboarded_at` nil check in
the redirect, the keep-first-timestamp rule, the track constraint, the user scope on `?project=`, the
`return_to` allowlist, and the folder check in the `files#create` redirect.

All three backend legs must report the same RUN count; any test gated to some backends is gated with
a skip, not left out of a leg.

## Out of scope

- Coach marks or tooltips over the real UI.
- Storing which track someone picked.
- Cataloguing models sooner after every upload app-wide (only the 3D Done step enqueues the job).
- Following a zip upload from the wizard to its unpack page and back.
- A per-user "don't show again" separate from `onboarded_at`.
