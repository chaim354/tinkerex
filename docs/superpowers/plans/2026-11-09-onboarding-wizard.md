# Onboarding Wizard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **In this repo `.claude/commands/execute-plan.md` overrides the generic loop** (CLAUDE.md §15): batch by file, parallel where independent, no spec-compliance stage, one capped quality review per task.

**Goal:** A person whose account was just made is walked once through a five-step wizard (Choose · Tour · Project · Files · Done) on a files track or a 3D-models track, ending on a real first project with real files filed into it.

**Architecture:** One boolean, `users.onboarding_pending`, set by the four doors that make an account for a person and cleared by Skip or by a project created in the wizard. Recent (`HomeController#index`) is the only page that redirects into the wizard. A new `WelcomeController` renders the five steps; project creation moves into a shared `Maker::CreateProject` service that `ProjectsController#create` also calls; the top bar's Upload learns one optional "where to go after" (`upload_return`), which `FilesController#create` honours through an allowlisted `return_to` flag and the chunk uploader through its existing `redirectUrl` value.

**Tech Stack:** Rails 8.1, Hotwire/Stimulus (no new JS), Minitest request + system tests, SQLite.

**Spec:** `docs/superpowers/specs/2026-11-09-onboarding-wizard-design.md`. Branch `claude/onboarding-wizard` (already created; the spec is its first commit).

---

## Executing this plan

- **Task order:** Tasks 1 and 2 touch disjoint files and can run in parallel. Task 3 needs both. Task 4 needs Task 3's routes. Task 5 needs Task 4. Task 6 is the close-out.
- **Running tests.** A bare `bin/rails test` errors ~187 times for want of a library. Always:
  ```bash
  LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test test/path/to_test.rb
  ```
  Two implementers running tests at once must not share the test database. The second one uses its own:
  ```bash
  DATABASE_URL=sqlite3:storage/test_task2.sqlite3 RAILS_ENV=test LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails db:schema:load
  DATABASE_URL=sqlite3:storage/test_task2.sqlite3 LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test test/path/to_test.rb
  ```
- **Ruby edit scripts** run under `LANG=en_US.UTF-8 ruby -Eutf-8:utf-8` (the Bash tool's locale is US-ASCII). Prefer the Edit tool.
- **Commit messages** go through a file (`git commit -F tmp/msg.txt`). A backtick inside `-m "…"` runs as a command in zsh.
- **Mutation checks come AFTER the task's commit.** `git checkout -- <file>` restores to HEAD, so running it before committing destroys the task. After each restore, clear the bootsnap cache, then confirm `git status --porcelain` is clean:
  ```bash
  find tmp/cache -maxdepth 1 -name 'bootsnap*' -exec rm -rf {} +
  ```
  If implementers share one tree, they do not commit or run `git checkout`. The orchestrator commits each task with pathspecs, then runs that task's mutation checks.
- **Never dodge a new redirect** by marking a test user not pending. Any test, other than the two named in Task 3, that newly sees `302 → /welcome` was created through one of the four doors. Update it to expect the wizard, and say so in the report.

## File map

| File | Task | Responsibility |
|---|---|---|
| `db/migrate/20261109120000_add_onboarding_pending_to_users.rb` | 1 | The one column |
| `db/schema.rb`, `docs/schema-map.html` | 1 | Dumped schema and its generated map |
| `app/controllers/users/registrations_controller.rb` | 1 | Sign-up marks the account pending |
| `app/controllers/settings/users_controller.rb` | 1 | An account an admin adds is pending |
| `lib/tasks/tinkerex.rake` | 1 | `tinkerex:owner` marks the account pending |
| `app/models/user.rb` | 1 | `from_omniauth`'s new-account branch is pending |
| `test/integration/web/auth_first_run_test.rb`, `test/integration/web/registration_flow_test.rb`, `test/integration/web/settings_users_test.rb`, `test/tasks/tinkerex_tasks_test.rb`, `test/models/user_omniauth_test.rb` | 1 | One assertion per door |
| `app/services/maker/create_project.rb` (new) | 2 | Save + folder + the two sentences |
| `app/controllers/projects_controller.rb` | 2 | `#create` calls the service; three private helpers deleted |
| `test/services/maker/create_project_test.rb` (new) | 2 | The service |
| `app/services/mcp_server/tools/projects.rb`, `test/integration/web/project_edit_area_test.rb`, `test/integration/web/notice_grammar_test.rb` | 2 | Comments that named the deleted helpers |
| `config/routes.rb` | 3 | The wizard's seven routes |
| `app/controllers/welcome_controller.rb` (new) | 3 | The five steps + skip |
| `app/views/welcome/*.html.erb` (new: `choose`, `tour`, `_tour_files`, `_tour_models`, `new_project`, `files`, `done`, `_steps`, `_skip`) | 3 | The pages |
| `app/views/home/_file_card.html.erb` (new) | 3 | Recent's file tile, extracted for Done |
| `app/views/home/index.html.erb` | 3 | Uses the extracted tile; "Take the tour" link |
| `app/controllers/home_controller.rb` | 3 | The one redirect into the wizard |
| `app/views/help/show.html.erb` | 3 | "Take the tour" link |
| `app/helpers/shell_helper.rb` | 3 | `welcome` lights Recent |
| `app/assets/stylesheets/pages/home.css` | 3 | Wizard layout (page classes, no component selectors) |
| `test/integration/web/welcome_test.rb` (new) | 3, 4 | The wizard's request tests |
| `test/integration/web/registration_mode_test.rb`, `test/integration/web/settings_library_test.rb` | 3 | A new owner now lands on the wizard |
| `app/controllers/concerns/folder_destination.rb` | 4 | `upload_return` / `use_upload_return` |
| `app/views/layouts/_topbar_upload.html.erb` | 4 | `return_to` field / uploader redirect value |
| `app/controllers/files_controller.rb` | 4 | The `return_to` branch in `#create` |
| `test/integration/web/files_welcome_return_test.rb` (new) | 4 | `files#create`'s return |
| `test/system/onboarding_test.rb` (new) | 5 | Both tracks in a browser |
| `test/system/accent_spend_test.rb` | 5 | The wizard's pages in the accent table |

---

### Task 1: `users.onboarding_pending` and the four doors that set it

**Files:**
- Create: `db/migrate/20261109120000_add_onboarding_pending_to_users.rb`
- Modify: `db/schema.rb`, `docs/schema-map.html` (generated)
- Modify: `app/controllers/users/registrations_controller.rb` (`#build_resource`, ~line 159)
- Modify: `app/controllers/settings/users_controller.rb` (`#create`, line 28)
- Modify: `lib/tasks/tinkerex.rake` (`tinkerex:owner`, line 24)
- Modify: `app/models/user.rb` (`self.from_omniauth`, the `new(email:)` branch, ~line 285)
- Test: `test/integration/web/auth_first_run_test.rb`, `test/integration/web/registration_flow_test.rb`, `test/integration/web/settings_users_test.rb`, `test/tasks/tinkerex_tasks_test.rb`, `test/models/user_omniauth_test.rb`

- [ ] **Step 1: Write the failing assertions, one per door**

`test/integration/web/auth_first_run_test.rb`, in "the card's form makes the confirmed owner and admin, signed in":
```ruby
      owner = User.find_by!(email: "owner@example.com")
      assert owner.confirmed?
      assert owner.admin?
      assert owner.onboarding_pending?, "the owner is shown the onboarding wizard on first sign-in"
```

`test/integration/web/registration_flow_test.rb`, in "a new maker is told an email was sent, on the page they actually land on":
```ruby
      email = sign_up!
      assert User.exists?(email:), "the account should exist"
      assert User.find_by!(email:).onboarding_pending?, "every sign-up is shown the wizard, not only the owner's"
```

`test/integration/web/settings_users_test.rb`, in "adding an account makes a confirmed account that signs in, …":
```ruby
      created = User.find_by!(email: "new@example.com")
      assert created.confirmed?
      assert_not created.admin?
      assert created.onboarding_pending?, "the person an admin added is shown the onboarding wizard"
```

`test/tasks/tinkerex_tasks_test.rb`, in "owner creates a confirmed account that can sign in":
```ruby
    u = User.find_by!(email: "maker@example.com")
    assert u.confirmed?
    assert u.valid_password?(PASSWORD)
    assert u.onboarding_pending?, "the account made at the console is shown the wizard on its first web sign-in"
```

`test/models/user_omniauth_test.rb`, in "from_omniauth creates a confirmed user + identity for a new provider account":
```ruby
    assert user.confirmed?, "an IdP-verified email is treated as confirmed"
    assert user.onboarding_pending?, "a first IdP sign-in is a new person, shown the wizard"
```

- [ ] **Step 2: Run them to see them fail**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test test/integration/web/auth_first_run_test.rb test/integration/web/registration_flow_test.rb test/integration/web/settings_users_test.rb test/tasks/tinkerex_tasks_test.rb test/models/user_omniauth_test.rb
```
Expected: errors `NoMethodError: undefined method 'onboarding_pending?'` (the column does not exist yet).

- [ ] **Step 3: Write the migration**

`db/migrate/20261109120000_add_onboarding_pending_to_users.rb`:
```ruby
# THE ONBOARDING WIZARD'S ONE PIECE OF STATE (2026-11-09; docs/superpowers/specs/
# 2026-11-09-onboarding-wizard-design.md). TRUE ONLY WHERE A DOOR SAYS SO: the four that make an
# account for a person — sign-up, Settings → Users, `tinkerex:owner` and a first OIDC sign-in — set
# it, and Skip or a project made in the wizard clears it (WelcomeController). THE DEFAULT IS FALSE,
# and that is the whole migration: every existing account, the nightly demo account and every
# account a test or a console makes stays off the wizard with no backfill. A person who already
# uses the app is never sent on a tour of it.
class AddOnboardingPendingToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :onboarding_pending, :boolean, null: false, default: false
  end
end
```

- [ ] **Step 4: Put the column in `db/schema.rb` by hand, where a migrating database holds it**

Rails 8.1.4 dumps columns in PHYSICAL order, and this checkout's long-lived dev database differs from `schema.rb` in most tables. A `db:migrate` here would rewrite columns it never touched. So edit two lines by hand:

```ruby
ActiveRecord::Schema[8.1].define(version: 2026_11_09_120000) do
```
and in `create_table "users"`, directly after the last column line `t.json "pinned_tools", default: [], null: false`:
```ruby
    t.boolean "onboarding_pending", default: false, null: false
```

Then prove the file round-trips: load it into a scratch SQLite database, dump it, and compare. Write `tmp/schema_roundtrip.rb`:
```ruby
require "tmpdir"
Dir.mktmpdir do |dir|
  ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: File.join(dir, "rt.sqlite3"))
  ActiveRecord::Schema.verbose = false
  load Rails.root.join("db/schema.rb").to_s
  out = StringIO.new
  ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection_pool, out)
  same = out.string == Rails.root.join("db/schema.rb").read
  File.write(Rails.root.join("tmp/schema.dumped.rb"), out.string) unless same
  puts(same ? "ROUNDTRIP-OK" : "ROUNDTRIP-DIFF: see tmp/schema.dumped.rb")
end
```
```bash
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails runner -e test tmp/schema_roundtrip.rb
```
Expected: `ROUNDTRIP-OK`. On a diff, `diff db/schema.rb tmp/schema.dumped.rb`, move the line to where the dump puts it, and re-run. Then `rm tmp/schema_roundtrip.rb tmp/schema.dumped.rb`.

Load it into the test database and regenerate the schema map:
```bash
RAILS_ENV=test LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails db:schema:load
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails schema:map
```

- [ ] **Step 5: Mark the four doors**

`app/controllers/users/registrations_controller.rb`, in `#build_resource`:
```ruby
    def build_resource(hash = {})
      super
      # EVERY PERSON WHO SIGNS UP IS SHOWN THE ONBOARDING WIZARD ONCE (2026-11-09) — the owner and a
      # later sign-up alike, so this sits ABOVE the first-owner return. A door, not a User callback,
      # for the reason the admin flag is one: a callback would also mark the demo account and every
      # account the suite makes.
      resource.onboarding_pending = true
      return unless Tinkerex::Registration.first_owner?
```

`app/controllers/settings/users_controller.rb`, `#create`:
```ruby
      @new_user = User.new(new_user_params.merge(confirmed_at: Time.current, admin: params.dig(:user, :admin) == "1",
                                                 onboarding_pending: true))
```

`lib/tasks/tinkerex.rake`, `tinkerex:owner`: replace the comment line `# The first account is the admin (Settings → Users), as the sign-up form's is.` and the `User.create!` line under it with:
```ruby
    # The first account is the admin (Settings → Users), as the sign-up form's is. Pending, as every
    # door's person is: the owner made here meets the onboarding wizard on their first web sign-in.
    user = User.create!(email:, password: pw, confirmed_at: Time.current, admin: first, onboarding_pending: true)
```

`app/models/user.rb`, `self.from_omniauth`:
```ruby
      else
        # No collision: a brand-new account, so trusting the provider email is safe. A new person,
        # so shown the onboarding wizard as a sign-up is.
        new(email:, onboarding_pending: true)
      end
```

- [ ] **Step 6: Run the five files; expect green**

The same command as Step 2. Expected: 0 failures, 0 errors.

- [ ] **Step 7: Commit**

`tmp/msg.txt`:
```
A person's new account is marked for the onboarding wizard

users.onboarding_pending, false by default, so existing accounts, the
demo account and every account a test or a console makes are untouched.
The four doors that make an account for a person set it: sign-up,
Settings > Users, tinkerex:owner, and a first OIDC sign-in.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```
```bash
git add db/migrate/20261109120000_add_onboarding_pending_to_users.rb db/schema.rb docs/schema-map.html app/controllers/users/registrations_controller.rb app/controllers/settings/users_controller.rb lib/tasks/tinkerex.rake app/models/user.rb test/integration/web/auth_first_run_test.rb test/integration/web/registration_flow_test.rb test/integration/web/settings_users_test.rb test/tasks/tinkerex_tasks_test.rb test/models/user_omniauth_test.rb
git commit -F tmp/msg.txt
```

- [ ] **Step 8: Mutation-check each door (after the commit)**

For each of the four, delete the `onboarding_pending` line or argument, run its test file, record the actual red output, `git checkout -- <file>`, and clear bootsnap:
1. `registrations_controller.rb`: `auth_first_run_test` and `registration_flow_test` go red.
2. Move the line BELOW `return unless …first_owner?`: `registration_flow_test` alone goes red (the owner case stays green). This is why both assertions exist.
3. `settings/users_controller.rb`: `settings_users_test` goes red.
4. `tinkerex.rake`: `tinkerex_tasks_test` goes red.
5. `user.rb`: `user_omniauth_test` goes red.

---

### Task 2: `Maker::CreateProject`, shared by New project and the wizard

**Files:**
- Create: `app/services/maker/create_project.rb`
- Create: `test/services/maker/create_project_test.rb`
- Modify: `app/controllers/projects_controller.rb` (`#create` at line 559; delete `#ensure_project_folder`, `#created_notice` and `#folder_failure_alert`, lines ~758–803, with their comments)
- Modify (comments only): `app/services/mcp_server/tools/projects.rb:92`, `test/integration/web/project_edit_area_test.rb:12`, `test/integration/web/notice_grammar_test.rb:13`

- [ ] **Step 1: Write the failing service test**

`test/services/maker/create_project_test.rb`:
```ruby
require "test_helper"

module Maker
  # ONE WAY TO START A PROJECT FROM A FORM (onboarding wizard, 2026-11-09): New project and the
  # wizard's Project step. A real share library per test, because making the folder IS the point:
  # rows alone would let a regression in the minting branch pass (project-intake.md says so of the
  # door tests in projects_flow_test.rb, which keep covering ProjectsController#create unchanged).
  class CreateProjectTest < ActiveSupport::TestCase
    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "create-#{SecureRandom.hex(4)}@example.com",
                           password: "correct horse battery staple", confirmed_at: Time.current)
    end

    test "saves the project, makes its folder, and names the folder in the notice" do
      project = @user.maker_projects.new(name: "Desk Lamp")
      result = Maker::CreateProject.call(@user, project)

      assert result.created?
      assert @root.join("Projects", "desk-lamp").directory?
      assert_equal @user.nodes.present.find_by!(name: "desk-lamp", kind: "dir").node_id, project.reload.folder_node_id
      assert_equal "Created Desk Lamp. Its folder is Projects/desk-lamp.", result.notice
      assert_nil result.alert
    end

    test "an invalid project is not created and makes no folder" do
      result = Maker::CreateProject.call(@user, @user.maker_projects.new(name: ""))

      assert_not result.created?
      assert_not @root.join("Projects").exist?
      assert result.project.errors[:name].any?
    end

    test "an unreachable library keeps the project and says to try again, never the class name" do
      project = @user.maker_projects.new(name: "Lamp")
      project.define_singleton_method(:ensure_library_folder!) { |_user| raise FileLayer::FetchError, "mount gone" }
      result = Maker::CreateProject.call(@user, project)

      assert result.created?
      assert_equal "Created Lamp.", result.notice
      assert_match(/could not be reached/, result.alert)
      assert_no_match(/FileLayer/, result.alert)
    end

    test "a name in the way keeps the project and says the folder could not be made" do
      project = @user.maker_projects.new(name: "Lamp")
      project.define_singleton_method(:ensure_library_folder!) { |_user| raise FileLayer::UnsupportedOperation, "taken" }
      result = Maker::CreateProject.call(@user, project)

      assert result.created?
      assert_match(/could not be made in the library/, result.alert)
    end
  end
end
```

- [ ] **Step 2: Run it to see it fail**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test test/services/maker/create_project_test.rb
```
Expected: `NameError: uninitialized constant Maker::CreateProject`.

- [ ] **Step 3: Write the service**

`app/services/maker/create_project.rb`. The sentences and the rescue move here VERBATIM from `ProjectsController`, so New project's flash does not change by a character:
```ruby
module Maker
  # ONE WAY TO START A PROJECT FROM A FORM (onboarding wizard, 2026-11-09): save it, make its
  # `Projects/<slug>` folder, and say what happened in the maker's terms. ProjectsController#create
  # and WelcomeController#create_project both call it (§14d: a verb more than one controller
  # performs gets a named service), so the two doors cannot drift on the folder or the sentences.
  # The MCP server's create_project keeps its own copy on purpose: its sentences are written for an
  # assistant and it lets every error but the two port failures propagate.
  #
  # The caller BUILDS the project, so a door can refuse it before anything is saved
  # (ProjectsController#demo_may_publish?) and re-render the same object with its errors.
  #
  # A FOLDER FAILURE IS NOT A CREATE FAILURE (stage 4, S4-6; story 1.2). The project is saved first
  # and stays saved; the folder is best-effort, and `alert` says WHICH problem it hit —
  # FileLayer::FetchError (try again) or anything else (FileLayer::UnsupportedOperation never
  # succeeds on retry) — as a sentence, never the class name, which a maker cannot act on (UX audit
  # C10). The class and message go to the log, where an operator reads. "The next time you open the
  # project" is literal: ProjectsController#show re-ensures the folder on every render.
  class CreateProject
    UNREACHABLE = "The library could not be reached, so the project folder was not created yet. It is made " \
                  "the next time you open the project while the library is available.".freeze
    REFUSED = "The project folder could not be made in the library; a file or folder there may already " \
              "have its name. It is tried again each time you open the project.".freeze

    Result = Data.define(:project, :failure) do
      def created? = project.persisted?

      # THE FOLDER IS NAMED FROM THE SLUG, NOT LOOKED UP, and that is exact here: a project made
      # through this service always reaches ensure_library_folder!'s minting branch (a brand-new
      # project has no folder_node_id), and that branch builds [ROOT, slug] literally.
      #
      # THE FAILURE IS AN ALERT BESIDE THE NOTICE, never folded into it (2026-11-02): the project WAS
      # created, which is news, and its folder was not, which is a problem — and a problem in a
      # `flash-notice` is drawn under the word "Done".
      def notice
        return "Created #{project.name}." if failure

        "Created #{project.name}. Its folder is #{Maker::ProjectFolders::ROOT}/#{project.slug}."
      end

      def alert
        return if failure.nil?

        failure == :unreachable ? UNREACHABLE : REFUSED
      end
    end

    def self.call(user, project)
      return Result.new(project:, failure: nil) unless project.save

      Result.new(project:, failure: ensure_folder(user, project))
    end

    def self.ensure_folder(user, project)
      project.ensure_library_folder!(user)
      nil
    rescue FileLayer::FetchError => e
      log_failure(project, e)
      :unreachable
    rescue StandardError => e
      log_failure(project, e)
      :refused
    end

    def self.log_failure(project, error)
      Rails.logger.warn("[projects] folder ensure failed for #{project.slug}: #{error.class} #{error.message}")
    end
    private_class_method :ensure_folder, :log_failure
  end
end
```

- [ ] **Step 4: Run the service test; expect green**

The same command as Step 2. Expected: 4 runs, 0 failures.

- [ ] **Step 5: Point `ProjectsController#create` at the service**

Replace the body of `#create`:
```ruby
  def create
    @project = current_user.maker_projects.new(project_params)
    result = Maker::CreateProject.call(current_user, @project) if demo_may_publish?(@project)
    if result&.created?
      redirect_to project_path(@project), notice: result.notice, alert: result.alert
    else
      render :new, status: :unprocessable_entity
    end
  end
```
Delete the three now-unused private methods, each with its comment block: `#ensure_project_folder`, whose comment starts `# Best-effort: a project MUST save even if the library backend…`; `#created_notice`, whose comment starts `# THE FOLDER IS NAMED FROM THE SLUG, NOT LOOKED UP…`; and `#folder_failure_alert`. Check that nothing else in the file calls them:
```bash
grep -n "ensure_project_folder\|created_notice\|folder_failure_alert" app/controllers/projects_controller.rb
```
Expected: no output.

- [ ] **Step 6: Sweep the comments that named the deleted helpers**

- `app/services/mcp_server/tools/projects.rb:92`: `ProjectsController#ensure_project_folder's best effort` → `Maker::CreateProject's best effort`.
- `test/integration/web/project_edit_area_test.rb:12`: `ProjectsController#ensure_project_folder returning` → `Maker::CreateProject.ensure_folder returning`.
- `test/integration/web/notice_grammar_test.rb:13`: `(\`created_notice\`,` → `(\`Maker::CreateProject::Result#notice\`,`.

Then check that nothing else still names them (plans under `docs/superpowers/plans/` are dated history; leave them):
```bash
grep -rn "ensure_project_folder\|created_notice\|folder_failure_alert" app lib test docs/invariants | grep -v releases_controller
```
Expected: no output.

- [ ] **Step 7: Run the service test and every existing `projects#create` test; expect green unchanged**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test test/services/maker/create_project_test.rb test/integration/web/projects_flow_test.rb test/integration/web/project_edit_area_test.rb test/integration/web/notice_grammar_test.rb test/integration/web/demo_guards_test.rb
```
Expected: 0 failures, 0 errors. No existing test was edited apart from the two comments, which is the check that the extraction kept behaviour.

- [ ] **Step 8: Commit**

`tmp/msg.txt`:
```
New project's save-and-folder step is a service the wizard can share

Maker::CreateProject saves a built project, makes its Projects/<slug>
folder best-effort, and carries the same notice and alert sentences
ProjectsController#create used, moved verbatim.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```
```bash
git add app/services/maker/create_project.rb test/services/maker/create_project_test.rb app/controllers/projects_controller.rb app/services/mcp_server/tools/projects.rb test/integration/web/project_edit_area_test.rb test/integration/web/notice_grammar_test.rb
git commit -F tmp/msg.txt
```

- [ ] **Step 9: Mutation-check (after the commit)**

1. Swap the two `rescue` clauses' return values (`:refused` for FetchError): the unreachable test goes red.
2. Make `alert` return `failure.to_s`: both failure tests go red.
3. In `self.call`, replace `failure: ensure_folder(user, project)` with `failure: nil` (never make the folder): the first test goes red on the missing directory.

Restore each one with `git checkout -- app/services/maker/create_project.rb` and clear bootsnap.

---

### Task 3: The wizard (routes, controller, pages, the Recent redirect, the links)

**Files:**
- Modify: `config/routes.rb` (after `get "help", to: "help#show", as: :help`, line 502)
- Create: `app/controllers/welcome_controller.rb`
- Create: `app/views/welcome/_steps.html.erb`, `_skip.html.erb`, `choose.html.erb`, `tour.html.erb`, `_tour_files.html.erb`, `_tour_models.html.erb`, `new_project.html.erb`, `files.html.erb`, `done.html.erb`
- Create: `app/views/home/_file_card.html.erb`
- Modify: `app/views/home/index.html.erb` (lines 27–66), `app/controllers/home_controller.rb` (`#index`), `app/views/help/show.html.erb` (line 3), `app/helpers/shell_helper.rb` (line 14), `app/assets/stylesheets/pages/home.css` (append inside `@layer pages`)
- Create: `test/integration/web/welcome_test.rb`
- Modify: `test/integration/web/registration_mode_test.rb`, `test/integration/web/settings_library_test.rb`

- [ ] **Step 1: Write the failing request tests**

`test/integration/web/welcome_test.rb`:
```ruby
require "test_helper"

module Web
  # THE ONBOARDING WIZARD (2026-11-09; docs/superpowers/specs/2026-11-09-onboarding-wizard-design.md):
  # five steps a person whose account was just made walks once, on a files track or a 3D-models
  # track. Every test runs on all three backend legs. A test that MAKES a folder pins a fresh share
  # library (project-intake.md: rows alone hide a broken minting branch); a test that only READS one
  # uses port-free rows (project_folder_rows!).
  class WelcomeTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup do
      @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV.delete("DEMO_ACCOUNT_EMAIL")
      @user = User.create!(email: "welcome-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current, onboarding_pending: true)
      sign_in_web!(@user, password: PASSWORD)
    end

    teardown { @prior_demo ? ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo : ENV.delete("DEMO_ACCOUNT_EMAIL") }

    def project_with_rows(name = "Lamp")
      project = @user.maker_projects.create!(name:)
      [ project, project_folder_rows!(@user, project) ]
    end

    def dir_row(name, parent)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "dir", parent_node_id: parent.node_id, mtime: 1, size: 0)
    end

    def file_row(name, parent)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id: parent.node_id, mtime: 1, size: 5)
    end

    # ---------------------------------------------------------------- when it opens

    test "a pending account is sent from Recent to the wizard" do
      get root_path
      assert_redirected_to welcome_path
      follow_redirect!
      assert_select ".page-head h1", "What will you mostly use Tinkerex for?"
      assert_select "a.welcome-choice[href=?]", welcome_tour_path(track: "files")
      assert_select "a.welcome-choice[href=?]", welcome_tour_path(track: "models")
    end

    test "an account that is not pending stays on Recent, and can still open the wizard" do
      @user.update_column(:onboarding_pending, false)
      get root_path
      assert_response :success
      assert_select ".page-head h1", "Recent"
      get welcome_path
      assert_response :success
    end

    test "the demo account is never sent to the wizard" do
      ENV["DEMO_ACCOUNT_EMAIL"] = @user.email
      get root_path
      assert_response :success
      assert_select ".page-head h1", "Recent"
    end

    test "Skip clears the pending state and goes to Recent" do
      post welcome_skip_path
      assert_redirected_to root_path
      assert_not @user.reload.onboarding_pending?
      follow_redirect!
      assert_response :success
    end

    test "Recent's getting-started panel and Help both link to the tour" do
      @user.update_column(:onboarding_pending, false)
      get root_path
      assert_select ".getting-started a[href=?]", welcome_path
      get help_path
      assert_select ".page-head a[href=?]", welcome_path, text: "Take the tour"
    end

    test "the wizard's pages light Recent in the rail" do
      get welcome_path
      assert_select ".rail-link[title=Recent][aria-current=page]"
    end

    # ---------------------------------------------------------------- tour

    test "an unknown track is a 404" do
      get "/welcome/printing/tour"
      assert_response :not_found
    end

    test "each track's tour shows its own cards and leads to its project step" do
      get welcome_tour_path(track: "models")
      assert_select ".welcome-card h2", text: "A 3D viewer that speaks millimetres"
      assert_select ".welcome-card h2", text: "Cut files, measured", count: 0
      assert_select "a.btn.primary[href=?]", welcome_project_path(track: "models")

      get welcome_tour_path(track: "files")
      assert_select ".welcome-card h2", text: "Cut files, measured"
      assert_select ".welcome-card h2", text: "A 3D viewer that speaks millimetres", count: 0
      assert_select "a.btn.primary[href=?]", welcome_project_path(track: "files")
    end

    # ---------------------------------------------------------------- project

    test "the files track asks for a kind, offering every one but 3D printing" do
      get welcome_project_path(track: "files")
      assert_select "form[action=?]", welcome_project_path(track: "files") do
        assert_select "input[name=?]", "project[name]"
        assert_select "textarea[name=?]", "project[description]"
        assert_select "select[name=?] option", "project[kind]", count: Maker::Project::KINDS.size - 1
        assert_select "select[name=?] option[value=print]", "project[kind]", count: 0
      end
    end

    test "the 3D track states its kind and asks for none" do
      get welcome_project_path(track: "models")
      assert_select "select[name=?]", "project[kind]", count: 0
      assert_select ".welcome-kind", text: /3D printing project/
    end

    test "creating a project clears the pending state, makes its folder, and goes to Files" do
      @root = use_fresh_share_library!
      post welcome_project_path(track: "files"),
           params: { project: { name: "Desk Lamp", description: "A lamp.", kind: "laser" } }

      project = @user.maker_projects.find_by!(name: "Desk Lamp")
      assert_redirected_to welcome_files_path(track: "files", project: project.slug)
      assert_equal "laser", project.kind
      assert_not @user.reload.onboarding_pending?
      assert @root.join("Projects", project.slug).directory?
      assert_equal "Created Desk Lamp. Its folder is Projects/desk-lamp.", flash[:notice]
    end

    test "the 3D track saves kind print whatever the form sends" do
      @root = use_fresh_share_library!
      post welcome_project_path(track: "models"), params: { project: { name: "Bracket", kind: "laser" } }
      assert_equal "print", @user.maker_projects.find_by!(name: "Bracket").kind
    end

    test "a blank name re-renders the step with its error and keeps the account pending" do
      assert_no_difference -> { @user.maker_projects.count } do
        post welcome_project_path(track: "files"), params: { project: { name: "" } }
      end
      assert_response :unprocessable_entity
      assert_select ".form-errors"
      assert @user.reload.onboarding_pending?
    end

    # ---------------------------------------------------------------- files and done

    test "files and done are 404 for another user's project or a missing one" do
      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      theirs = other.maker_projects.create!(name: "Theirs")
      get welcome_files_path(track: "files", project: theirs.slug)
      assert_response :not_found
      get welcome_done_path(track: "files", project: theirs.slug)
      assert_response :not_found
      get welcome_files_path(track: "files", project: "no-such-project")
      assert_response :not_found
    end

    test "the Files step aims the top bar's Upload at the project folder and makes it the accent" do
      project, = project_with_rows
      get welcome_files_path(track: "models", project: project.slug)
      assert_response :success
      assert_select "header.topbar .topbar-upload-caption", text: "Saves to Projects/lamp"
      assert_select "header.topbar .upload-btn.primary", count: 1
      assert_select ".welcome-files code", text: "models/"
      assert_select "a[href=?]", welcome_done_path(track: "models", project: project.slug), text: "I'll add files later"
    end

    test "the files track's Files step names the shelves from the user's own filing rules" do
      project, = project_with_rows
      get welcome_files_path(track: "files", project: project.slug)
      shelves = Maker::FilingRules.for(@user)
      assert_select ".welcome-files code", text: "#{shelves.fetch('svg', Maker::ProjectFolders::OTHER)}/"
      assert_select ".welcome-files code", text: "#{shelves.fetch('lbrn2', Maker::ProjectFolders::OTHER)}/"
    end

    test "with the project's folder gone, the Files step says so and aims Upload nowhere" do
      project, folder = project_with_rows
      folder.update_column(:deleted, true)
      get welcome_files_path(track: "files", project: project.slug)
      assert_select ".welcome-folder-pending"
      assert_select "header.topbar .topbar-upload-caption", text: /Saves to/, count: 0
    end

    test "Done lists what landed by folder, and the 3D track starts the model catalog" do
      project, folder = project_with_rows
      stl = file_row("bracket.stl", dir_row("models", folder))
      readme = file_row("README.md", folder)
      [ stl, readme ].each { |n| project.file_attachments.create!(user: @user, node_id: n.node_id) }

      assert_enqueued_with(job: Maker::ModelIntakeJob, args: [ { user_id: @user.id } ]) do
        get welcome_done_path(track: "models", project: project.slug)
      end
      assert_select ".page-head h1", "Lamp is ready"
      assert_select ".welcome-landed h3", text: "Project folder"
      assert_select ".welcome-landed h3", text: "models/"
      assert_select ".welcome-landed .grid-name", text: "bracket.stl"
      assert_select "a.btn.primary[href=?]", project_path(project), text: "Open Lamp"
      assert_select "a[href=?]", files_models_path, text: "Go to 3D models"
    end

    test "the files track's Done starts no catalog run and links to the project's folder" do
      project, folder = project_with_rows
      assert_no_enqueued_jobs(only: Maker::ModelIntakeJob) do
        get welcome_done_path(track: "files", project: project.slug)
      end
      assert_select ".welcome-empty", text: %r{Projects/lamp}
      assert_select "a[href=?]", files_path(folder: folder.node_id), text: "Go to Library"
    end
  end
end
```

The two existing tests that follow a new owner's sign-up onto Recent now expect the wizard:

`test/integration/web/registration_mode_test.rb`, "the first account is confirmed without mail, signed in, and closes sign-up behind it":
```ruby
      owner = User.find_by!(email: "owner@example.com")
      assert owner.confirmed?, "the owner needs no confirmation mail"
      follow_redirect!
      # Recent, which sends a person whose account was just made on to the onboarding wizard.
      assert_redirected_to welcome_path
      follow_redirect!
      assert_response :success, "signed in and landed on a real page, not bounced to the sign-in page"
```

`test/integration/web/settings_library_test.rb`: rename the test to `"a fresh install's first sign-up lands on the library page on share, on the onboarding wizard elsewhere"` and change its `else` branch:
```ruby
      else
        # Recent, which sends the new owner on to the onboarding wizard (2026-11-09).
        assert_redirected_to welcome_path
        follow_redirect!
        assert_response :success
      end
```

- [ ] **Step 2: Run them to see them fail**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test test/integration/web/welcome_test.rb test/integration/web/registration_mode_test.rb test/integration/web/settings_library_test.rb
```
Expected: `NameError: undefined local variable or method 'welcome_path'` across the file.

- [ ] **Step 3: Add the routes**

`config/routes.rb`, directly after `get "help", to: "help#show", as: :help`:
```ruby

  # THE ONBOARDING WIZARD (2026-11-09; docs/superpowers/specs/2026-11-09-onboarding-wizard-design.md).
  # The track lives in the URL and THE CONSTRAINT IS ITS ONLY CHECK: anything but `files` or `models`
  # is a 404 before WelcomeController runs, which renders a track's pages by comparing against
  # "models" and would otherwise show the files track for any word at all.
  get  "welcome",      to: "welcome#choose", as: :welcome
  post "welcome/skip", to: "welcome#skip",   as: :welcome_skip
  scope "welcome/:track", constraints: { track: /files|models/ } do
    get  "tour",    to: "welcome#tour",           as: :welcome_tour
    get  "project", to: "welcome#new_project",    as: :welcome_project
    post "project", to: "welcome#create_project"
    get  "files",   to: "welcome#files",          as: :welcome_files
    get  "done",    to: "welcome#done",           as: :welcome_done
  end
```

- [ ] **Step 4: Write the controller**

`app/controllers/welcome_controller.rb`:
```ruby
# THE ONBOARDING WIZARD (2026-11-09; docs/superpowers/specs/2026-11-09-onboarding-wizard-design.md):
# five pages a person walks once — Choose, Tour, Project, Files, Done — on one of two tracks, `files`
# (laser, CNC, electronics, documents) or `models` (3D printing). The track lives in the URL, where
# config/routes.rb constrains it, and is never stored. The one piece of state is
# `users.onboarding_pending`: the doors that make an account for a person set it, Recent sends a
# pending account here (HomeController#index, the only redirect in), and Skip or a project made here
# clears it. Anyone can walk it again from Recent's Getting started panel or from Help.
class WelcomeController < ApplicationController
  # "Edit in <Addon>" on Done's file tiles, as Recent's tiles have it.
  include AddonOrigins

  STEPS = { choose: "Choose", tour: "Tour", project: "Project", files: "Files", done: "Done" }.freeze

  # THE FILES TRACK OFFERS EVERY KIND BUT `print`, which is the 3D track's — stated there, not asked.
  FILES_KINDS = (Maker::Project::KINDS - %w[print]).freeze

  # The extensions whose shelf the Files step names, read from the user's own filing rules so a
  # renamed shelf shows its new name (Maker::FilingRules; Settings → Shelves).
  NAMED_EXTS = %w[svg lbrn2 pdf stl].freeze

  # What Done lists. A project made a minute ago holds what was just uploaded, so this bounds an odd
  # case; it is not a page size.
  LANDED_LIMIT = 48

  helper_method :track
  before_action :set_project, only: %i[files done]

  def choose; end

  def tour; end

  def skip
    finish_onboarding!
    redirect_to root_path, status: :see_other
  end

  def new_project
    @project = current_user.maker_projects.new(kind: track == "models" ? "print" : "mixed")
  end

  def create_project
    @project = current_user.maker_projects.new(project_attributes)
    result = Maker::CreateProject.call(current_user, @project)
    return render(:new_project, status: :unprocessable_entity) unless result.created?

    # A PROJECT MADE HERE ENDS THE PENDING STATE, not Done, which is a page a closed tab never
    # reaches: a person who made a project and walked away must not be sent back to make a second.
    finish_onboarding!
    redirect_to welcome_files_path(track:, project: @project.slug), notice: result.notice, alert: result.alert
  end

  # Upload is this page's one action, aimed at the project's folder and pointed back at Done
  # (FolderDestination#use_upload_return, Task 4). The folder is ensured best-effort first, as
  # ProjectsController#show does: a create whose folder failed gets another try on every visit, and
  # a port failure renders the folder-pending state instead of a 500.
  def files
    @folder = project_folder
    if @folder
      use_folder_destination(@folder.node_id, path: Maker::LibraryTree.new(current_user).path_for(@folder.node_id),
                                              primary: true)
    end
    rules = Maker::FilingRules.for(current_user)
    @shelves = NAMED_EXTS.index_with { |ext| rules.fetch(ext, Maker::ProjectFolders::OTHER) }
  end

  def done
    # THE CATALOG RUNS NOW ON THE 3D TRACK, NOT ON THE NEXT SCAN. On share and s3 a web upload is
    # catalogued by Library::ScanJob every 15 minutes, so an STL uploaded a moment ago would not be in
    # 3D models yet. The upload's filing sweep already moved it under models/ before the redirect
    # here, which is the order model-intake.md requires; Files::UnpacksController#finish enqueues the
    # same job for the same reason. One per user, duplicates discarded, so a reload costs nothing.
    Maker::ModelIntakeJob.perform_later(user_id: current_user.id) if track == "models"
    @groups = landed_groups
    ids = @groups.values.flatten.map(&:node_id)
    @covers = Maker::Previews::ThumbnailMap.for(current_user, ids)
    @addon_origins = addon_origins_for(ids)
  end

  private

  def track = params[:track]

  def set_project
    @project = current_user.maker_projects.find_by!(slug: params[:project].to_s)
  end

  def finish_onboarding!
    current_user.update_column(:onboarding_pending, false) if current_user.onboarding_pending?
  end

  def project_attributes
    attrs = params.require(:project).permit(:name, :description, :kind)
    attrs[:kind] = "print" if track == "models"
    attrs
  end

  def project_folder
    @project.ensure_library_folder!(current_user)
  rescue StandardError
    nil
  end

  # WHAT LANDED, grouped by the folder each file sits in. The project's ATTACHMENTS, because the
  # upload's filing sweep attaches before it moves (Maker::ProjectIntake), so an attachment is
  # exactly "a file this project holds", filed or not. A nil key is the project folder itself (a
  # README is never filed); it sorts first. Two queries, whatever the count.
  def landed_groups
    ids = @project.file_attachments.limit(LANDED_LIMIT).pluck(:node_id)
    nodes = current_user.nodes.present.where(node_id: ids, kind: "file").order(:name).to_a
    names = current_user.nodes.where(node_id: nodes.map(&:parent_node_id).uniq).pluck(:node_id, :name).to_h
    nodes.group_by { |node| node.parent_node_id == @project.folder_node_id ? nil : names[node.parent_node_id] }
         .sort_by { |folder, _| folder.to_s }.to_h
  end
end
```

- [ ] **Step 5: Write the shared partials and the five pages**

`app/views/welcome/_steps.html.erb`:
```erb
<%# locals: (current:) %>
<%# WHERE THE PERSON IS IN THE FIVE STEPS. Text, not links: Back and Next on each page are the way
    between steps, so a step not reached yet is never a link to a page that needs a project nobody
    has made. A native <ol>, so a screen reader hears the count. %>
<ol class="welcome-steps">
  <% WelcomeController::STEPS.each do |key, label| %>
    <%= tag.li label, class: ("is-current" if key == current), "aria-current": ("step" if key == current) %>
  <% end %>
</ol>
```

`app/views/welcome/_skip.html.erb`:
```erb
<%# QUIET ON PURPOSE: each step has one accent action, and leaving is never it (design-system.md rule 13). %>
<%= button_to "Skip for now", welcome_skip_path, class: "linkbtn", form_class: "welcome-skip" %>
```

`app/views/welcome/choose.html.erb`:
```erb
<% content_for :title, "Welcome — Tinkerex" %>
<div class="page-head"><h1>What will you mostly use Tinkerex for?</h1></div>
<%= render "welcome/steps", current: :choose %>
<%# NO ACCENT ON THIS PAGE: the two cards are equal and neither is the default. %>
<p class="welcome-lede">Pick one to see the parts of Tinkerex that matter most for it, then set up
  your first project. Everything works either way.</p>
<div class="welcome-choices">
  <%= link_to welcome_tour_path(track: "files"), class: "welcome-choice" do %>
    <h2>Organize my files</h2>
    <p>Laser, CNC, electronics and documents.</p>
  <% end %>
  <%= link_to welcome_tour_path(track: "models"), class: "welcome-choice" do %>
    <h2>Organize my 3D models</h2>
    <p>STL, 3MF, STEP and prints.</p>
  <% end %>
</div>
<%= render "welcome/skip" %>
```

`app/views/welcome/tour.html.erb`. The render paths are literals, never interpolated from params, so Brakeman has nothing to flag:
```erb
<% content_for :title, "Tour — Tinkerex" %>
<div class="page-head"><h1><%= track == "models" ? "Tinkerex for your 3D models" : "Tinkerex for your files" %></h1></div>
<%= render "welcome/steps", current: :tour %>
<div class="welcome-cards">
  <%= render(track == "models" ? "welcome/tour_models" : "welcome/tour_files") %>
</div>
<div class="welcome-nav">
  <%= link_to "Back", welcome_path, class: "btn" %>
  <%= link_to "Next: your first project", welcome_project_path(track:), class: "btn primary" %>
  <%= render "welcome/skip" %>
</div>
```

`app/views/welcome/_tour_files.html.erb`. Every sentence is either the app's own verified copy (the landing page's, `shared/_where_files_come_from`) or checked against the code named here. Change the behaviour, change the sentence:
```erb
<%# THE FILES TRACK'S CARDS. Sentences reused from the landing page (landings/show) and
    shared/_where_files_come_from, which were checked against the code; the tools named are in the
    addons bundle's manifests. %>
<article class="panel welcome-card">
  <h2>Your library is a folder</h2>
  <%= render "shared/where_files_come_from", projects: false %>
  <p class="welcome-where">It is <%= link_to "Library", files_path %>, in the sidebar.</p>
</article>
<article class="panel welcome-card">
  <h2>Previews for what you make</h2>
  <p>SVG, DXF, PDF, LightBurn, Gerber boards, images and code open in the browser, and the Library
    shows a thumbnail of each.</p>
</article>
<article class="panel welcome-card">
  <%= image_tag "landing/measure.jpg", width: 1120, height: 700, loading: "lazy", class: "welcome-shot",
                alt: "The Measure view: a LightBurn file's shapes, each one clickable to measure" %>
  <h2>Cut files, measured</h2>
  <p>LightBurn, SVG and DXF files show their real size, and print at 1:1 to check against stock.</p>
</article>
<article class="panel welcome-card">
  <%= image_tag "landing/project.jpg", width: 1120, height: 700, loading: "lazy", class: "welcome-shot",
                alt: "A project page: its cover, its file count and its recently changed files" %>
  <h2>A folder becomes a project</h2>
  <%= render "shared/where_files_come_from", sources: false %>
</article>
<article class="panel welcome-card">
  <%= image_tag "landing/boxes.jpg", width: 1120, height: 700, loading: "lazy", class: "welcome-shot",
                alt: "The box generator: a box's size and material settings beside a preview of its cut sheet" %>
  <h2>Tools that make files</h2>
  <p>The Box Generator, Labels and Text to Outline make cut files and save them straight into your
    library.</p>
  <p class="welcome-where"><%= link_to "Tools", tools_path %>, in the sidebar.</p>
</article>
```

`app/views/welcome/_tour_models.html.erb`. The model sentences are the Help page's (`help/show`, checked against `docs/invariants/model-intake.md`):
```erb
<%# THE 3D TRACK'S CARDS. The catalog, print-log and Printables sentences are the Help page's
    (help/show, checked against docs/invariants/model-intake.md), the viewer's the landing page's;
    the tools named are in the addons bundle's manifests. %>
<article class="panel welcome-card">
  <h2>Models find themselves</h2>
  <p>A 3D file loose at the top of the library, in a top-level folder, in <code>Models/</code> or in
    a project's <code>models/</code> folder is a model of its own, and a folder inside a top-level
    folder or a <code>models/</code> folder is one model holding what is inside it. New files become
    models on the next library scan.</p>
  <p class="welcome-where"><%= link_to "3D models", files_models_path %>, in the sidebar.</p>
</article>
<article class="panel welcome-card">
  <%= image_tag "landing/viewer.jpg", width: 1120, height: 700, loading: "lazy", class: "welcome-shot",
                alt: "The 3D viewer: a model turned in the browser, its size on three axes beneath it" %>
  <h2>A 3D viewer that speaks millimetres</h2>
  <p>STL, 3MF, STEP and a dozen more open in the browser with their size on three axes.</p>
</article>
<article class="panel welcome-card">
  <h2>A print log for every model</h2>
  <p>A model's page keeps its print log. A failed print waits under <em>Needs attention</em> on
    Recent for a week, or until a later print of that model is logged.</p>
</article>
<article class="panel welcome-card">
  <h2>Bring in a download</h2>
  <p>A model downloaded from Printables as a zip comes in whole with
    <%= link_to "Import a Printables zip", new_model_path %>, which unpacks it into <code>Models/</code>
    with its pictures and instructions.</p>
</article>
<article class="panel welcome-card">
  <h2>Tools that make printable parts</h2>
  <p>Gridfinity Bins, Simple Parts, Lithophane and OpenSCAD make printable files and save them
    straight into your library.</p>
  <p class="welcome-where"><%= link_to "Tools", tools_path %>, in the sidebar.</p>
</article>
```

`app/views/welcome/new_project.html.erb`. The field names are asserted on the rendered page in `welcome_test.rb` (§14d: `scope:` is what makes them `project[...]`):
```erb
<% content_for :title, "Your first project — Tinkerex" %>
<div class="page-head"><h1>Your first project</h1></div>
<%= render "welcome/steps", current: :project %>
<%= form_with model: @project, scope: :project, url: welcome_project_path(track:), method: :post,
              class: "project-form" do |f| %>
  <% if @project.errors.any? %>
    <div class="form-errors flash-alert" role="alert"><%= @project.errors.full_messages.to_sentence %></div>
  <% end %>
  <label class="field">
    <span>Name</span>
    <%= f.text_field :name, required: true, autofocus: true %>
  </label>
  <label class="field">
    <span>Description</span>
    <%= f.text_area :description, rows: 3, placeholder: "What are you building?" %>
  </label>
  <% if track == "models" %>
    <p class="welcome-kind">This will be a 3D printing project. You can change its type later, from
      the project's Edit page.</p>
  <% else %>
    <label class="field">
      <span>Type</span>
      <%= f.select :kind, options_for_select(WelcomeController::FILES_KINDS.map { |k| [ Maker::ProjectKind.label(k), k ] },
                                             @project.kind) %>
      <span class="field-hint muted">Sets which panels the project's page shows. You can change it later.</span>
    </label>
  <% end %>
  <p class="muted welcome-other-way">A folder you put directly inside <code>Projects/</code> becomes a
    project on its own, too.</p>
  <div class="welcome-nav">
    <%= link_to "Back", welcome_tour_path(track:), class: "btn" %>
    <%= f.submit "Create project", class: "btn primary" %>
  </div>
<% end %>
<%= render "welcome/skip" %>
```

`app/views/welcome/files.html.erb`. There is no Back link: going back to Project would make a second project.
```erb
<% content_for :title, "Add files — Tinkerex" %>
<div class="page-head"><h1>Add files to <%= @project.name %></h1></div>
<%= render "welcome/steps", current: :files %>
<% if @folder %>
  <div class="welcome-files">
    <p>Use <strong>Upload</strong> in the top bar: it saves into <code><%= folder_destination.caption %></code>,
      this project's folder.</p>
    <% if track == "models" %>
      <p>STL and 3MF files go into <code><%= @shelves.fetch("stl") %>/</code>, and each one becomes a
        model under <%= link_to "3D models", files_models_path %>.</p>
    <% else %>
      <p>Files you add at the top of the folder are filed into type folders: an SVG into
        <code><%= @shelves.fetch("svg") %>/</code>, a LightBurn file into <code><%= @shelves.fetch("lbrn2") %>/</code>,
        a PDF into <code><%= @shelves.fetch("pdf") %>/</code>. A README stays where it is.</p>
    <% end %>
    <%= render "shared/where_files_come_from", projects: false %>
  </div>
<% else %>
  <div class="welcome-folder-pending flash-alert" role="alert">
    <p>This project's folder is not in the library yet, so there is nowhere to upload to. It is made
      the next time this page or the project opens while the library is available.</p>
    <p><%= link_to "Try again", welcome_files_path(track:, project: @project.slug) %></p>
  </div>
<% end %>
<div class="welcome-nav">
  <%= link_to "I'll add files later", welcome_done_path(track:, project: @project.slug), class: "linkbtn" %>
</div>
```

`app/views/welcome/done.html.erb`. Hash arguments in `render` are spelled out, because ERB's shorthand swallows the next line:
```erb
<% content_for :title, "#{@project.name} is ready — Tinkerex" %>
<div class="page-head"><h1><%= @project.name %> is ready</h1></div>
<%= render "welcome/steps", current: :done %>
<% if @groups.any? %>
  <section class="welcome-landed" data-controller="thumbs filemenu" data-thumbs-url-value="<%= thumbnails_files_path %>">
    <% @groups.each do |folder, nodes| %>
      <h3><%= folder ? "#{folder}/" : "Project folder" %></h3>
      <div class="recent-grid">
        <% nodes.each do |node| %>
          <%= render "home/file_card", node: node, covers: @covers, origins: @addon_origins %>
        <% end %>
      </div>
    <% end %>
  </section>
  <% if track == "models" %>
    <p class="muted">Your 3D files are being added to <%= link_to "3D models", files_models_path %> now.</p>
  <% end %>
<% else %>
  <p class="welcome-empty">No files yet. Anything you put in
    <code><%= Maker::ProjectFolders::ROOT %>/<%= @project.slug %></code> is filed into this project.</p>
<% end %>
<div class="welcome-nav">
  <%= link_to "Open #{@project.name}", project_path(@project), class: "btn primary" %>
  <% if track == "models" %>
    <%= link_to "Go to 3D models", files_models_path, class: "btn" %>
  <% else %>
    <%= link_to "Go to Library", (@project.folder_node_id ? files_path(folder: @project.folder_node_id) : files_path),
                class: "btn" %>
  <% end %>
</div>
```

- [ ] **Step 6: Extract Recent's file tile and add the two links**

`app/views/home/_file_card.html.erb`. This is the body of Recent's loop, unchanged apart from `@covers`/`@addon_origins` becoming locals:
```erb
<%# locals: (node:, covers:, origins:) %>
<%# ONE FILE TILE AS RECENT DRAWS IT, extracted (2026-11-09) so the onboarding wizard's Done step draws
    its files the same way: the same thumb_cell_data/file_menu_data wire contract
    (docs/invariants/files-preview.md), not a second copy of it. `covers` is a
    Maker::Previews::ThumbnailMap over these nodes; `origins` is AddonOrigins#addon_origins_for's hash. %>
<% ext_label = File.extname(node.name).delete(".").upcase.first(4) %>
<% href = file_path(node.node_id) %>
<% if Maker::Previews::Registry.for_filename(node.name).present? %>
  <%= link_to href, class: "grid-card file-cell",
              data: file_open_data(thumb_cell_data(node.node_id, ext_label).merge(file_menu_data(node, origins[node.node_id]))) do %>
    <%= render "files/thumb", thumb: covers.thumb(node.node_id), ext_label: ext_label,
               url: preview_src(covers.thumb(node.node_id)), photo: Maker::FileAttachment.photo?(node.name) %>
    <span class="grid-name"><%= node.name %></span>
  <% end %>
<% else %>
  <%= link_to href, class: "grid-card", data: file_open_data(file_menu_data(node, origins[node.node_id])) do %>
    <span class="thumb generic-thumb" aria-hidden="true"><%= ext_label.presence || "FILE" %></span>
    <span class="grid-name"><%= node.name %></span>
  <% end %>
<% end %>
```

In `app/views/home/index.html.erb`, replace the loop body (lines 50–66, from `<% @recent_files.each do |node| %>` to its `<% end %>`):
```erb
      <% @recent_files.each do |node| %>
        <%= render "home/file_card", node: node, covers: @covers, origins: @addon_origins %>
      <% end %>
```
In the same file, make the tour link the panel's first line, directly after `<div class="panel-head"><h2>Getting started</h2>…</div>`:
```erb
    <p class="getting-started-tour"><%= link_to "Take the tour", welcome_path %>: it walks you through
      what Tinkerex does and sets up your first project.</p>
```

`app/views/help/show.html.erb`, line 3:
```erb
<div class="page-head"><h1>Help</h1><div class="head-actions"><%= link_to "Take the tour", welcome_path, class: "btn" %></div></div>
```

`app/helpers/shell_helper.rb`, line 14:
```ruby
    # The onboarding wizard (2026-11-09) is Recent's own flow — the page it opens from — so it lights Recent.
    "home" => %w[home welcome],
```

- [ ] **Step 7: Add the one redirect into the wizard**

`app/controllers/home_controller.rb`, first lines of `#index`:
```ruby
  def index
    # A PERSON WHOSE ACCOUNT WAS JUST MADE IS SHOWN THE ONBOARDING WIZARD FIRST (2026-11-09), from here
    # and nowhere else: sign-in lands on Recent, so this is the first page a new account opens, while a
    # link from anywhere else to a file still works. Never the demo account, whose visitor came to
    # look around (Tinkerex::Demo).
    return redirect_to(welcome_path) if current_user.onboarding_pending? && !Tinkerex::Demo.demo?(current_user)

```
(Keep the existing body below it.)

- [ ] **Step 8: Style it in Recent's sheet**

Append inside the `@layer pages { … }` block of `app/assets/stylesheets/pages/home.css`, before its closing `}`. Only page classes, no component selector (design-system.md rule 3). No accent: each step's one action is a `.btn.primary` or the top bar's Upload.
```css

  /* THE ONBOARDING WIZARD (2026-11-09), which lights Recent and so lives in Recent's sheet. Built
     from the app's own components — `.panel` cards, `.btn` buttons, `.recent-grid` tiles — so what is
     here is the step rail, the two choice cards and the spacing between. Nothing is accent: each
     step's one action is a `.btn.primary` or the top bar's Upload (design-system.md rule 13). */
  .welcome-steps { display: flex; flex-wrap: wrap; gap: var(--space-2) var(--space-5); margin: 0 0 var(--space-5);
                   padding: 0; list-style-position: inside; font-size: 13px; color: var(--fg-muted); }
  .welcome-steps > li::marker { font-weight: 600; }
  .welcome-steps > li.is-current { color: var(--fg); font-weight: 600; }
  .welcome-lede, .welcome-files, .welcome-kind, .welcome-other-way, .welcome-empty { max-width: var(--prose-measure); }
  .welcome-lede { color: var(--fg-muted); }
  .welcome-choices { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: var(--space-4);
                     max-width: 720px; margin: var(--space-4) 0 var(--space-5); }
  .welcome-choice { display: block; padding: var(--space-5); border: 1px solid var(--line); border-radius: var(--radius-panel);
                    background: var(--surface); color: var(--fg); text-decoration: none; }
  .welcome-choice:hover, .welcome-choice:focus-visible { border-color: var(--fg-muted); }
  .welcome-choice h2 { margin: 0 0 var(--space-1); font-size: 17px; }
  .welcome-choice p { margin: 0; color: var(--fg-muted); }
  .welcome-cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); gap: var(--space-4); }
  .welcome-card h2 { margin-bottom: var(--space-2); font-size: 15px; }
  .welcome-card p { color: var(--fg-muted); }
  .welcome-card strong { color: var(--fg); font-weight: 600; }
  .welcome-shot { display: block; width: 100%; height: auto; margin-bottom: var(--space-3);
                  border: 1px solid var(--line); border-radius: var(--radius-control); }
  .welcome-where { font-size: 13px; }
  .welcome-nav { display: flex; flex-wrap: wrap; gap: var(--space-3); align-items: center; margin-top: var(--space-5); }
  .welcome-landed h3 { margin: var(--space-4) 0 var(--space-2); font-size: 13px; color: var(--fg-muted); }
  .getting-started-tour { margin-bottom: var(--space-4); }
```

- [ ] **Step 9: Run the wizard's tests, the two updated ones and Recent's own; expect green**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test test/integration/web/welcome_test.rb test/integration/web/registration_mode_test.rb test/integration/web/settings_library_test.rb test/integration/web/home_test.rb test/integration/web/help_page_test.rb test/integration/web/template_hygiene_test.rb test/css_hygiene_test.rb test/stimulus_hygiene_test.rb test/integration/web/page_query_budget_test.rb
```
Expected: 0 failures, 0 errors. Then run the whole share leg once and fix anything that newly sees `302 → /welcome`, following the rule at the top of this plan:
```bash
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test
```

- [ ] **Step 10: Commit**

`tmp/msg.txt`:
```
The onboarding wizard: two tracks from a new account to its first project

Choose, Tour, Project, Files and Done at /welcome, on a files track or a
3D-models track. Recent sends a pending account there; Skip or a created
project ends it; Recent's Getting started panel and Help reopen it. Done
lists what landed by folder, and on the 3D track starts the model catalog.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```
```bash
git add config/routes.rb app/controllers/welcome_controller.rb app/views/welcome app/views/home/_file_card.html.erb app/views/home/index.html.erb app/controllers/home_controller.rb app/views/help/show.html.erb app/helpers/shell_helper.rb app/assets/stylesheets/pages/home.css test/integration/web/welcome_test.rb test/integration/web/registration_mode_test.rb test/integration/web/settings_library_test.rb
git commit -F tmp/msg.txt
```
Add any test file Step 9's full run made you update to this commit by name.

- [ ] **Step 11: Mutation-check (after the commit)**

Each mutation, its expected red test, then `git checkout -- <file>` and clear bootsnap:
1. `home_controller.rb`: drop `&& !Tinkerex::Demo.demo?(current_user)` → "the demo account is never sent…" goes red.
2. `home_controller.rb`: drop `current_user.onboarding_pending? &&` → "an account that is not pending stays on Recent…" goes red.
3. `config/routes.rb`: remove `constraints: { track: /files|models/ }` → "an unknown track is a 404" goes red (renders the files tour, 200).
4. `welcome_controller.rb`: `find_by!(slug:)` from `Maker::Project` instead of `current_user.maker_projects` → "files and done are 404 for another user's project" goes red.
5. `welcome_controller.rb`: delete `attrs[:kind] = "print" if track == "models"` → "the 3D track saves kind print…" goes red.
6. `welcome_controller.rb`: delete `finish_onboarding!` from `#create_project` → "creating a project clears the pending state…" goes red.
7. `welcome_controller.rb`: delete the `perform_later` line → "Done lists what landed…" goes red.
8. `shell_helper.rb`: remove `welcome` → "the wizard's pages light Recent in the rail" goes red.

---

### Task 4: Upload comes back to Done

**Files:**
- Modify: `app/controllers/concerns/folder_destination.rb`
- Modify: `app/views/layouts/_topbar_upload.html.erb`
- Modify: `app/controllers/files_controller.rb` (`#create` ~line 860; a private method above `# WHERE A RENAME OR MOVE LANDS`, ~line 1918)
- Modify: `app/controllers/welcome_controller.rb` (`#files`)
- Create: `test/integration/web/files_welcome_return_test.rb`
- Modify: `test/integration/web/welcome_test.rb` (one test)

- [ ] **Step 1: Write the failing tests**

`test/integration/web/files_welcome_return_test.rb`:
```ruby
require "test_helper"

module Web
  # THE WIZARD'S UPLOAD COMES BACK TO DONE (2026-11-09; onboarding spec, "Getting back to the wizard
  # after an upload"). files#create honours `return_to` only as an allowlisted flag naming a track,
  # and only for an upload into one of the user's own project folders. A fresh share library pins the
  # port, so this POSTs bytes on every leg and the three report the same runs; the chunk uploader's
  # half (a redirect value the page renders) is welcome_test.rb's.
  class FilesWelcomeReturnTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    STL = "solid b\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid b\n".freeze
    SVG = %(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10"/></svg>\n).freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "return-#{SecureRandom.hex(4)}@example.com", password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Lamp")
      @project.ensure_library_folder!(@user)
    end

    def upload(files, parent_node_id: @project.folder_node_id, **extra)
      list = files.map { |name, bytes| Rack::Test::UploadedFile.new(StringIO.new(bytes), "application/octet-stream", original_filename: name) }
      post files_path, params: { file: list.size == 1 ? list.first : list, parent_node_id: }.merge(extra)
    end

    test "an upload from the 3D track's Files step lands on its Done step, already filed" do
      upload({ "bracket.stl" => STL }, return_to: "welcome_models")
      assert_redirected_to welcome_done_path(track: "models", project: @project.slug)
      node = @user.nodes.present.find_by!(name: "bracket.stl")
      assert_equal "models", @user.nodes.find_by!(node_id: node.parent_node_id).name, "filed before the redirect"
      assert flash[:notice].present?
    end

    test "a batch from the files track lands on Done too" do
      upload({ "a.svg" => SVG, "b.svg" => SVG }, return_to: "welcome_files")
      assert_redirected_to welcome_done_path(track: "files", project: @project.slug)
    end

    test "an unknown return_to redirects as before" do
      upload({ "a.svg" => SVG }, return_to: "https://elsewhere.example/")
      assert_redirected_to %r{/files/[^/]+\z}
    end

    test "a flag on an upload into a folder that is no project's changes nothing" do
      cad = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "cad")
      upload({ "a.svg" => SVG }, parent_node_id: cad.node_id, return_to: "welcome_files")
      assert_redirected_to %r{/files/[^/]+\z}
    end

    # A README, because it is the one name the sweep never files (Maker::AttachToProject keeps a README
    # at the project root): the second copy meets the first at the root and is refused. An SVG would
    # not be: the first is filed into its shelf, so the second lands without a clash.
    test "a refused upload goes back as it always has, not to Done" do
      upload({ "README.md" => "# Lamp\n" }, return_to: "welcome_files")
      upload({ "README.md" => "# Lamp\n" }, return_to: "welcome_files")
      assert_response :redirect
      assert_no_match %r{/welcome/}, response.location
    end
  end
end
```

In `test/integration/web/welcome_test.rb`, add after "the Files step aims the top bar's Upload…":
```ruby
    # TWO WIRE SHAPES BEHIND ONE UPLOAD (§14a: port_writable? picks the door). Branched on the
    # capability, never skipped, so all three legs run it: share and s3 render the form's hidden
    # flag, chunk_remote the uploader's redirect value.
    test "the Files step points the top bar's Upload back at Done" do
      project, folder = project_with_rows
      get welcome_files_path(track: "models", project: project.slug)
      done = welcome_done_path(track: "models", project: project.slug)
      if FileLayer.current.capabilities.port_writable?
        assert_select "header.topbar form.uploader" do
          assert_select "input[type=hidden][name=return_to][value=?]", "welcome_models"
          assert_select "input[type=hidden][name=parent_node_id][value=?]", folder.node_id
        end
      else
        assert_select "header.topbar [data-controller=uploader][data-uploader-redirect-url-value=?]", done
        assert_select "header.topbar [data-controller=uploader][data-uploader-parent-node-id-value=?]", folder.node_id
      end
      # Every other page renders neither: Recent, with the account no longer pending so it stays there.
      @user.update_column(:onboarding_pending, false)
      get root_path
      assert_select "input[name=return_to]", count: 0
      assert_select "[data-uploader-redirect-url-value]", count: 0
    end
```

- [ ] **Step 2: Run them to see them fail**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test test/integration/web/files_welcome_return_test.rb test/integration/web/welcome_test.rb
```
Expected: the return tests redirect to `/files/<id>` instead of Done, and the hidden `return_to` is missing.

- [ ] **Step 3: Give FolderDestination its one new answer**

`app/controllers/concerns/folder_destination.rb`: add `:upload_return` to the `helper_method` line, then add below `use_folder_destination`:
```ruby

  # WHERE A SUCCESSFUL TOP-BAR UPLOAD GOES NEXT, on the one page that changes it: the onboarding
  # wizard's Files step (WelcomeController#files). `flag` is the allowlisted `return_to` the share/s3
  # form posts (FilesController#welcome_return_path reads it); `url` is the chunk uploader's
  # redirectUrl, which it follows after a clean run. nil on every other page, so
  # layouts/_topbar_upload renders exactly what it did before.
  UploadReturn = Data.define(:flag, :url)

  def upload_return = @upload_return
  def use_upload_return(flag, url:) = (@upload_return = UploadReturn.new(flag:, url:))
```
and change the `helper_method` line to:
```ruby
    helper_method :folder_destination, :upload_primary?, :upload_return
```

- [ ] **Step 4: Render it in the top bar**

`app/views/layouts/_topbar_upload.html.erb`, in the share/s3 form, directly after the `hidden_field_tag :parent_node_id …` call (its two lines):
```erb
      <%# THE WIZARD'S WAY BACK (2026-11-09): only WelcomeController#files sets upload_return, so every
          other page renders no field and files#create redirects as it always has. %>
      <% if upload_return %>
        <%= hidden_field_tag :return_to, upload_return.flag, id: nil %>
      <% end %>
```
In the chunk section's `data:` hash, add a line between `uploader_model_exts_value: Maker::FileAttachment::MODEL_EXTS,` and `upload_pick_target: ("uploader" if pick) } do %>`:
```erb
                            uploader_redirect_url_value: upload_return&.url,
```
A nil value writes no attribute, the same way `upload_pick_target` already relies on.

- [ ] **Step 5: Set it on the Files step**

`app/controllers/welcome_controller.rb`, `#files`, inside `if @folder`:
```ruby
    if @folder
      use_folder_destination(@folder.node_id, path: Maker::LibraryTree.new(current_user).path_for(@folder.node_id),
                                              primary: true)
      use_upload_return("welcome_#{track}", url: welcome_done_path(track:, project: @project.slug))
    end
```

- [ ] **Step 6: Honour it in `files#create`**

`app/controllers/files_controller.rb`, `#create`, between `intake_result = intake_project_folder(info.node_id)` and `if uploads.size > 1 || refused.any?`:
```ruby

    # THE ONBOARDING WIZARD'S WAY BACK (2026-11-09): an upload from its Files step lands on its Done
    # step, single or batch, with the notice it would have had anyway. After the sweep, so Done lists
    # the files already filed. HTML only: the JSON door's callers read a node_id, never a redirect.
    if request.format.html? && (done = welcome_return_path(params[:parent_node_id]))
      notice = if uploads.size > 1 || refused.any?
                 batch_upload_notice(written.map(&:name), intake_result, refused:)
               else
                 project_intake_notice(intake_result, uploads.first.original_filename)
               end
      return redirect_to(done, notice:)
    end
```
In the private section, directly above the comment line `# WHERE A RENAME OR MOVE LANDS, whichever way it went.`:
```ruby
  # WHERE THE WIZARD'S UPLOAD GOES BACK TO, or nil for every other upload. `return_to` IS AN
  # ALLOWLISTED FLAG NAMING A TRACK, NEVER A URL (rename_move_landing's rule, below), and the project
  # is found from the folder the bytes went into, so the flag on an upload anywhere else changes
  # nothing. layouts/_topbar_upload renders it, on WelcomeController#files alone.
  WELCOME_RETURNS = { "welcome_files" => "files", "welcome_models" => "models" }.freeze

  def welcome_return_path(parent_node_id)
    track = WELCOME_RETURNS[params[:return_to]]
    return if track.nil? || parent_node_id.blank?

    project = current_user.maker_projects.find_by(folder_node_id: parent_node_id.to_s)
    welcome_done_path(track:, project: project.slug) if project
  end

```

- [ ] **Step 7: Run them; expect green**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test test/integration/web/files_welcome_return_test.rb test/integration/web/welcome_test.rb test/integration/web/topbar_upload_test.rb test/integration/web/files_flow_test.rb
```
Expected: 0 failures, 0 errors.

- [ ] **Step 8: Run the chunk_remote leg for the two test files**

This page renders the other upload branch there, and that leg is the one a share-only run never sees:
```bash
bin/ci test-chunk-remote
```
Expected: green. If it is slow, run only the two files under that leg's environment; `config/ci.rb` defines it, so read the env from there rather than guessing it.

- [ ] **Step 9: Commit**

`tmp/msg.txt`:
```
An upload from the wizard's Files step lands on its Done step

The top bar's Upload takes one optional answer, upload_return, set only
by WelcomeController#files: an allowlisted return_to flag for the share
and s3 form, the uploader's redirectUrl for chunk_remote. files#create
honours the flag only for an upload into one of the user's project folders.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```
```bash
git add app/controllers/concerns/folder_destination.rb app/views/layouts/_topbar_upload.html.erb app/controllers/files_controller.rb app/controllers/welcome_controller.rb test/integration/web/files_welcome_return_test.rb test/integration/web/welcome_test.rb
git commit -F tmp/msg.txt
```

- [ ] **Step 10: Mutation-check (after the commit)**

1. `files_controller.rb`: replace `WELCOME_RETURNS[params[:return_to]]` with `params[:return_to].presence && "files"` → "an unknown return_to redirects as before" goes red.
2. `files_controller.rb`: drop the `find_by(folder_node_id:)` lookup and use `current_user.maker_projects.first` → "a flag on an upload into a folder that is no project's…" goes red.
3. `_topbar_upload.html.erb`: delete the `uploader_redirect_url_value` line → the chunk_remote leg's "points the top bar's Upload back at Done" goes red. Check it with `bin/ci test-chunk-remote`, the only leg that renders that branch.
4. `_topbar_upload.html.erb`: delete the `if upload_return` block → the share leg's same test goes red.

Restore each with `git checkout -- <file>` and clear bootsnap.

---

### Task 5: Both tracks in a browser, and the accent table

**Files:**
- Create: `test/system/onboarding_test.rb`
- Modify: `test/system/accent_spend_test.rb` (`expected` and `paths` in "every page spends the accent…")

- [ ] **Step 1: Write the system test**

`test/system/onboarding_test.rb`:
```ruby
require "application_system_test_case"

# THE ONBOARDING WIZARD IN A BROWSER (2026-11-09; docs/superpowers/specs/2026-11-09-onboarding-wizard-design.md).
# A request test sees each step's markup; only a browser walks the whole thing: Recent's redirect, a
# real project with a real folder, and the top bar's Upload landing on Done with the file already
# filed. Share only (use_fresh_share_library!), as topbar_upload_test.rb is; the chunk uploader's
# redirect value is asserted in welcome_test.rb.
class OnboardingSystemTest < ApplicationSystemTestCase
  STL = "solid b\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 10 0 0\nvertex 0 10 0\nendloop\nendfacet\nendsolid b\n".freeze
  SVG = %(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10"/></svg>\n).freeze

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("onboarding@example.com")
    @user.update_column(:onboarding_pending, true)
    @dir = Rails.root.join("tmp", "onboarding-#{SecureRandom.hex(4)}")
    @dir.mkpath
  end

  teardown do
    FileUtils.rm_rf(@dir)
    FileLayer.reset!
  end

  test "the 3D track ends on Done with the STL filed into models/" do
    stl = @dir.join("bracket.stl")
    File.write(stl, STL)

    visit root_path
    assert_current_path welcome_path
    click_on "Organize my 3D models"
    assert_selector ".welcome-card h2", text: "A 3D viewer that speaks millimetres"
    click_on "Next: your first project"
    fill_in "project[name]", with: "Wall Bracket"
    click_on "Create project"
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to Projects/wall-bracket"
    attach_file("topbar_upload_file", stl.to_s, make_visible: true)

    assert_selector ".page-head h1", text: "Wall Bracket is ready"
    assert_selector ".welcome-landed h3", text: "models/"
    assert_selector ".welcome-landed .grid-name", text: "bracket.stl"
    assert_not @user.reload.onboarding_pending?
    assert_no_console_errors
  end

  test "the files track ends on Done with the SVG filed into its type folder" do
    svg = @dir.join("panel.svg")
    File.write(svg, SVG)

    visit root_path
    click_on "Organize my files"
    click_on "Next: your first project"
    fill_in "project[name]", with: "Panel"
    select "Laser cutting", from: "project[kind]"
    click_on "Create project"
    attach_file("topbar_upload_file", svg.to_s, make_visible: true)

    assert_selector ".page-head h1", text: "Panel is ready"
    assert_selector ".welcome-landed h3", text: "#{Maker::ProjectFolders.folder_for(@user, 'panel.svg')}/"
    assert_selector ".welcome-landed .grid-name", text: "panel.svg"
    assert_equal "laser", @user.maker_projects.find_by!(name: "Panel").kind
    assert_no_console_errors
  end

  test "Skip for now leaves the wizard for good" do
    visit root_path
    click_on "Skip for now"
    assert_selector ".page-head h1", text: "Recent"
    visit root_path
    assert_current_path root_path
  end
end
```

- [ ] **Step 2: Add the wizard to the accent table**

In `test/system/accent_spend_test.rb`, at the end of the `expected` hash (after `"/settings/devices" => []`, adding the comma):
```ruby
      "/settings/devices" => [],
      # THE ONBOARDING WIZARD (2026-11-09): Choose spends nothing, its two cards being equal; Tour spends
      # its Next, Project its Create, Files the top bar's Upload (aimed at the new project's folder), and
      # Done its Open.
      "/welcome" => [],
      "/welcome/files/tour" => [ "Next: your first project" ],
      "/welcome/models/project" => [ "Create project" ],
      "/welcome/files/files" => [ "Upload" ],
      "/welcome/models/done" => [ "Open Desk Lamp" ]
```
At the end of the `paths` hash (after `"/settings/devices" => settings_devices_path`, adding the comma):
```ruby
      "/settings/devices" => settings_devices_path,
      "/welcome" => welcome_path,
      "/welcome/files/tour" => welcome_tour_path(track: "files"),
      "/welcome/models/project" => welcome_project_path(track: "models"),
      "/welcome/files/files" => welcome_files_path(track: "files", project: @project.slug),
      "/welcome/models/done" => welcome_done_path(track: "models", project: @project.slug)
```
Before trusting each expectation, open the page and confirm its text, because the table compares the rendered text. The Files step ensures the project's folder itself, on the share library this test pins, so map order does not matter.

- [ ] **Step 3: Run both; expect green**

```bash
LIBRARY_BACKEND=share LIBRARY_PATH="$(mktemp -d)" bin/rails test test/system/onboarding_test.rb test/system/accent_spend_test.rb
```
Expected: 0 failures, 0 errors. If a thumbnail request makes `assert_no_console_errors` fail on the SVG test, read the failing request with the console output first. Do not pass `ignoring:` to dodge it unless it is the same known noise another system test already ignores.

- [ ] **Step 4: Commit**

`tmp/msg.txt`:
```
Both onboarding tracks walked in a browser; the wizard in the accent table

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```
```bash
git add test/system/onboarding_test.rb test/system/accent_spend_test.rb
git commit -F tmp/msg.txt
```

- [ ] **Step 5: Mutation-check (after the commit)**

1. `app/views/welcome/tour.html.erb`: add `primary` to the Back link's class → accent table red on `/welcome/files/tour`.
2. `welcome_controller.rb`: `primary: false` in `#files` → accent table red on `/welcome/files/files` (`[]`).

Restore each with `git checkout -- <file>` and clear bootsnap.

---

### Task 6: Close-out (verify, PR, record)

- [ ] **Step 1: Bare `bin/ci`**

```bash
bin/ci
```
Expected: every gate green, and the three backend legs report identical RUN counts (`bin/ci` compares them itself). Paste the summary into the PR body.

- [ ] **Step 2: See it in the browser**

Follow the dev-server recipe: an empty dev DB, the ScanJob seed, and the demo one-click sign-in won't do, because the demo is never pending. **Before running `bin/rails db:migrate` on the dev database, confirm everything is committed.** Afterwards, `git checkout -- db/schema.rb` discards the physical-order re-dump. Then:

1. Make a pending account, e.g. `bin/rails runner 'User.create!(email: "new@example.test", password: "correct horse battery staple", confirmed_at: Time.current, onboarding_pending: true)'`.
2. Sign in and walk both tracks.
3. Take screenshots of Choose, one Tour, Project, Files and Done for each track, at desktop width and at phone width (`resize_window` preset mobile), in light and dark.
4. Check the console for errors on every step.
5. Attach the screenshots to the PR.

- [ ] **Step 3: Merge `origin/main` if it moved, then push and open the PR**

Before the final push of a branch that adds a migration, merge `origin/main` (a merge commit, not a rebase). On a `db/schema.rb` version conflict, keep the later timestamp and confirm both migrations' columns are present. Then re-run `test/schema_map_test.rb` and `bin/rails schema:map:check` under the library env. Use `/finish-branch`. Say in the PR body what was verified (bin/ci, legs, browser walk, mutation checks with their reds) and what was not.

- [ ] **Step 4: File the arc**

```bash
bin/log arc --from-pr <PR number>
```
`bin/log close <n>` happens at merge, which needs the owner's explicit go-ahead.
