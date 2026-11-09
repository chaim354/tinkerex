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
per-user onboarding state out of scope; this one adds exactly one column of it
(`users.onboarding_pending`) and nothing else. The wizard reuses `shared/_where_files_come_from` for every sentence about where
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

Five feature cards. Each has a title, one or two sentences, and, where it helps, where to find the
feature. Cards with a matching landing screenshot show it: `landing/viewer.jpg` is the 3D viewer,
`landing/measure.jpg` the Measure view, `landing/project.jpg` a project page, and
`landing/boxes.jpg` the box generator. `landing/library.jpg` is not used, because it is untracked
work in the owner's checkout.

**Every sentence is one the app already says and someone has checked.** It comes from the landing
page (`landings/show`), the Help page (`help/show`, checked against `model-intake.md`), or
`shared/_where_files_come_from`. The tools named are in the addons bundle's manifests. If the
behaviour changes, change the sentence.

**Files track**
1. **Your library is a folder.** `shared/_where_files_come_from` with `projects: false`.
2. **Previews for what you make.** SVG, DXF, PDF, LightBurn, Gerber boards, images and code open in
   the browser, and the Library shows a thumbnail of each. No screenshot.
3. **Cut files, measured.** The landing page's sentence. (`landing/measure.jpg`)
4. **A folder becomes a project.** `shared/_where_files_come_from` with `sources: false`, which
   covers filing and Shelves. (`landing/project.jpg`)
5. **Tools that make files.** The Box Generator, Labels and Text to Outline. (`landing/boxes.jpg`)

**3D track**
1. **Models find themselves.** The Help page's catalog sentence, plus "New files become models on
   the next library scan."
2. **A 3D viewer that speaks millimetres.** The landing page's sentence. (`landing/viewer.jpg`)
3. **A print log for every model.** The Help page's print-log sentence.
4. **Bring in a download.** The Help page's Printables-zip sentence, linking Import a Printables zip.
5. **Tools that make printable parts.** Gridfinity Bins, Simple Parts, Lithophane and OpenSCAD. No
   screenshot, because `landing/boxes.jpg` shows a laser-cut box. **Next** (the accent) goes to
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
success it clears `onboarding_pending` and redirects to the files step with `?project=<slug>`. On a validation error it re-renders this step with 422 and the model's
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

The page first ensures the folder best-effort, as the project page does on every render. If there
is still no live folder (a port failure, or a folder in the trash), the page says the folder is not
in the library yet, so there is nowhere to upload to, and that it is made the next time this page or
the project opens while the library is available. It offers **Try again** (this page) and **I'll add
files later**. Upload falls back to its folder chooser because no destination is set. There is no
Back link on this step, because going back to Project would make a second project.

### 5. Done — `GET /welcome/:track/done?project=<slug>`

"<Project> is ready." Then what landed: the project's file attachments, grouped by the folder each
one is filed in. Each file is drawn as Recent draws its tiles, so thumbnails fill in through the
existing polling. That tile is extracted from `home/index` into `home/_file_card` and shared. The
project page's own tile is not used, because it depends on that page's listing and carries Detach. With no attachments yet: "No files yet. Anything you add to
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

There is no "finish" request: reaching Done needs a project, and creating it already ended the
pending state.

## When it opens, and what ends it

- **One column:** `users.onboarding_pending`, a boolean, false by default. **It is true only where a
  door sets it.** Four doors make an account for a person, and each sets it:
  - sign-up (`Users::RegistrationsController#build_resource`, for the owner and every later sign-up);
  - Settings → Users;
  - `bin/rails tinkerex:owner`;
  - the new-account branch of `User.from_omniauth`.

  *Changed from the approved design's `users.onboarded_at`, where empty meant "show the wizard".*
  Measured while planning: the suite makes users with `User.create!` 548 times in 314 files, and 49
  test files open Recent. Under "empty means pending", every one of them would be redirected. With a
  false default and the doors setting it, those tests are untouched. So are existing accounts (no
  backfill needed) and the nightly demo account, which `Tinkerex::DemoReset` makes outside every
  door. A door added later that forgets to set it fails safe: its person never sees the wizard,
  rather than everyone seeing it.
- **Opens by itself in one place:** `HomeController#index` redirects to `/welcome` while
  `current_user.onboarding_pending?` and the user is not the demo account (`Tinkerex::Demo.demo?`).
  Sign-in already lands on Recent (`after_sign_in_path_for` → `root_path`), so this covers the first
  sign-in. On a share install whose library folder is not chosen yet, `require_library_folder!`
  runs first and sends the owner to Settings → Library, and the wizard follows. Nothing else
  redirects: a link from another page to a file works on a new account.
- **Ended** (set to false) by:
  - `POST /welcome/skip`, which then redirects to Recent;
  - a successful `POST /welcome/:track/project`.
  Closing the tab partway through the tour leaves it true, and the wizard opens again on the next
  visit to Recent. That is deliberate, since they have seen nothing yet.
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
- New styles (step rail, choice cards, tour cards) go in `pages/home.css`, Recent's sheet, inside its
  `@layer pages`. They are page classes (`.welcome-*`) built around the app's own components (`.panel`,
  `.btn`, `.recent-grid`), and no component selector is redefined (design-system.md rule 3). No new
  sheet, so the layout's link order and `css_hygiene_test.rb` stay as they are. Each page has at most
  one accent (rule 13), as listed per step above, and `accent_spend_test.rb` gains the five pages.

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
| Folder could not be made | Project still created, with New project's alert in the flash; the files step tries again and, failing, shows the folder-pending state above |
| Upload refused (name taken, reserved name) | Handled as today: the existing alert, back on the files step. Only an upload that landed at least one file goes to Done |
| Library unreachable during upload | The existing 503 handling; nothing new |
| Demo account | Never redirected to the wizard; can open it from the link like anyone |

## Testing

**Request tests** (`test/integration/web/welcome_test.rb`):
- Recent redirects to `/welcome` for a pending account; does not for one that is not pending; does
  not for the demo account even when pending.
- Skip clears `onboarding_pending` and redirects to Recent.
- Create project clears it, makes the project and its folder, and redirects to the files step. The 3D track saves kind `print` even when the request sends another kind. A blank name is 422
  and creates nothing.
- Unknown track 404s; another user's project slug 404s on files and done.
- The files step renders the top bar upload aimed at the project folder, with the return wiring
  asserted per flow. **This assertion branches on `port_writable?`**: the hidden `return_to` on share
  and s3, the uploader's redirect value on chunk_remote. A form-shaped assertion is red on the
  chunk_remote leg.
- `files#create` with `return_to=welcome_models` and a project-folder parent redirects to Done;
  with a parent that is no project's folder, or an unknown `return_to`, it redirects as before.
  It pins a fresh share library, so it POSTs bytes on every leg and the three legs run it alike
  (`files_welcome_return_test.rb`).
- The 3D Done step enqueues `Maker::ModelIntakeJob`; the files Done step does not.
- Project-folder fixtures are made port-free (`project_folder_rows!`) wherever the test is not about
  creating the folder.

**The doors:** one assertion per door that it sets `onboarding_pending`, in each door's existing test
(`auth_first_run_test`, `registration_flow_test`, `settings_users_test`, `tinkerex_tasks_test`,
`user_omniauth_test`). The two tests that follow a new owner's sign-up onto Recent
(`registration_mode_test`, `settings_library_test`) now expect the wizard.

**System tests** (`test/system/onboarding_test.rb`), on the system gate's backend: the files track
uploads an SVG and sees it on Done under its type folder; the 3D track uploads an STL and sees it
under `models/`.

**`Maker::CreateProject`:** a service test for the notice and both alerts. The existing
`projects#create` tests pass unchanged, which is the check that the extraction kept behavior.

**Mutation checks** (break, see red, restore): each door, the demo exclusion, the pending check in
the redirect, the track constraint, the user scope on `?project=`, the
`return_to` allowlist, and the folder check in the `files#create` redirect.

All three backend legs must report the same RUN count; any test gated to some backends is gated with
a skip, not left out of a leg.

## Out of scope

- Coach marks or tooltips over the real UI.
- Storing which track someone picked.
- Cataloguing models sooner after every upload app-wide (only the 3D Done step enqueues the job).
- Following a zip upload from the wizard to its unpack page and back.
- A per-user "don't show again" separate from `onboarding_pending`.
- The MCP server's `create_project` tool keeps its own folder step: its sentences are written for an
  assistant, and it lets every error but the two port failures propagate.
