# Admin user management Implementation Plan

> **For agentic workers:** in this repo, `.claude/commands/execute-plan.md` is the default way to run
> a plan with subagents (CLAUDE.md §15): batch by file, parallel where independent, no
> spec-compliance stage, one capped quality review per task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** An admin adds accounts, resets passwords, grants or removes admin and deletes accounts at
Settings → Users, with no console and no mail server.

**Architecture:** A new `users.admin` boolean, set by the doors that already decide "first account"
(sign-up form, `tinkerex:owner`) and backfilled onto the oldest real account by a data migration.
`User#can_manage_accounts?` is the one answer (the demo account never gets a yes). A session-authed
`Settings::UsersController` holds the list + add form (`index`/`create`) and one page per other
account (`edit`) with `reset_password`, `set_admin` and `destroy`. It never acts on the signed-in
account, which is what keeps at least one admin. The Account page's own delete refuses the last
admin while other accounts exist.

**Tech Stack:** Rails 8.1, Devise 5 (confirmable, lockable), Minitest integration tests, SQLite/Postgres.

**Spec:** `docs/superpowers/specs/2026-10-21-admin-users-design.md`.

**Running tests (a bare `bin/rails test` errors without the library env — §13):**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test <files>
```

---

## File map

| File | Change |
|---|---|
| `db/migrate/20261021120000_add_admin_to_users.rb` | create: the column |
| `db/migrate/20261021120100_mark_oldest_account_admin.rb` | create: the backfill |
| `db/schema.rb`, `docs/schema-map.html` | regenerated |
| `test/models/mark_oldest_account_admin_migration_test.rb` | create |
| `app/models/user.rb` | `can_manage_accounts?`, `account_managers`, `last_account_manager?` |
| `test/models/user_admin_test.rb` | create |
| `app/controllers/users/registrations_controller.rb` | first sign-up is admin; last-admin self-delete refusal |
| `lib/tasks/tinkerex.rake` | `owner` sets admin on the first account; new `admin` task |
| `test/integration/web/registration_mode_test.rb`, `test/tasks/tinkerex_tasks_test.rb`, `test/integration/web/account_settings_test.rb` | tests |
| `config/routes.rb` | `settings/users` |
| `app/controllers/settings/users_controller.rb` | create |
| `app/views/settings/users/index.html.erb`, `edit.html.erb` | create |
| `app/controllers/settings_controller.rb`, `app/views/settings/show.html.erb` | the hub row |
| `app/assets/stylesheets/pages/settings.css` | `.user-manage` spacing |
| `test/integration/web/settings_users_test.rb` | create |
| `test/integration/web/settings_hub_test.rb`, `test/integration/web/template_hygiene_test.rb` | the row; the two new templates |
| `docs/INSTALL.md`, `app/views/help/show.html.erb`, `CLAUDE.md` | docs |

---

### Task 1: The column and the backfill

**Files:**
- Create: `db/migrate/20261021120000_add_admin_to_users.rb`
- Create: `db/migrate/20261021120100_mark_oldest_account_admin.rb`
- Create: `test/models/mark_oldest_account_admin_migration_test.rb`
- Modify: `db/schema.rb` (generated), `docs/schema-map.html` (generated)

- [ ] **Step 1: Write the column migration**

```ruby
# WHO MAY MANAGE ACCOUNTS (2026-10-21; docs/superpowers/specs/2026-10-21-admin-users-design.md).
# Until now "the first account is the owner" was true only in that it came first: nothing recorded
# it, and every account could do everything. Default false: an account is an admin only when a door
# says so (the sign-up form's first account, `tinkerex:owner`'s first, `tinkerex:admin`, Settings →
# Users) or MarkOldestAccountAdmin backfills it.
class AddAdminToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :admin, :boolean, null: false, default: false
  end
end
```

- [ ] **Step 2: Write the failing backfill test**

```ruby
require "test_helper"
require Rails.root.join("db/migrate/20261021120100_mark_oldest_account_admin")

# AN EXISTING DEPLOYMENT GETS ITS ADMIN WITHOUT A CONSOLE VISIT. Driven directly (`.new.up`) rather
# than through the migrator, which would see the version already applied and run nothing (§14e's
# vacuous shape) -- confirm_existing_library_root_migration_test.rb's pattern.
class MarkOldestAccountAdminMigrationTest < ActiveSupport::TestCase
  setup do
    ActiveRecord::Migration.verbose = false
    User.delete_all
    @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV.delete("DEMO_ACCOUNT_EMAIL")
  end

  teardown do
    ActiveRecord::Migration.verbose = true
    @prior_demo ? ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo : ENV.delete("DEMO_ACCOUNT_EMAIL")
  end

  def account!(email) = User.create!(email:, confirmed_at: Time.current, omniauth_signup: true)

  test "the oldest account becomes the admin and no other" do
    oldest = account!("oldest@example.com")
    newer = account!("newer@example.com")

    MarkOldestAccountAdmin.new.up

    assert oldest.reload.admin?
    assert_not newer.reload.admin?
  end

  test "with no account it marks nobody" do
    MarkOldestAccountAdmin.new.up

    assert_equal 0, User.where(admin: true).count
  end

  test "where an admin already exists it marks nobody else, so a re-run adds none" do
    account!("oldest@example.com")
    chosen = account!("chosen@example.com")
    chosen.update!(admin: true)

    2.times { MarkOldestAccountAdmin.new.up }

    assert_equal [ chosen.id ], User.where(admin: true).pluck(:id)
  end

  # OVH's demo can be its oldest row. Marked, it would be an admin the predicate ignores and the
  # server would have none; passed over, the oldest real account gets the role.
  test "the demo account is passed over for the oldest real account" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    demo = account!("demo@example.com")
    real = account!("real@example.com")

    MarkOldestAccountAdmin.new.up

    assert_not demo.reload.admin?
    assert real.reload.admin?
  end
end
```

- [ ] **Step 3: Write the backfill migration**

```ruby
# AN EXISTING DEPLOYMENT GETS ITS ADMIN WITHOUT A CONSOLE VISIT: the oldest account, the one the
# sign-up page called the owner. A no-op where any admin already exists, so a re-run never makes a
# second. A fresh install has no account when this runs (and a new database loads schema.rb, which
# runs no migration), so its first account is made admin by the door that creates it instead.
#
# THE DEMO ACCOUNT IS PASSED OVER (Tinkerex::Demo, read from DEMO_ACCOUNT_EMAIL as this runs): it can
# never manage accounts (User#can_manage_accounts?), so marking it would leave the server with no
# working admin. With no demo configured, `email <> ''` passes over nobody -- email is never blank.
#
# RAW SQL, NOT the User model (a model drifts from the schema the migration saw), with the adapter's
# own spelling of true: 1 on SQLite, TRUE on Postgres.
class MarkOldestAccountAdmin < ActiveRecord::Migration[8.1]
  def up
    yes = connection.quoted_true
    demo = connection.quote(Tinkerex::Demo.email.to_s)
    execute <<~SQL.squish
      UPDATE users SET admin = #{yes}
      WHERE id = (SELECT MIN(id) FROM users WHERE email <> #{demo})
        AND NOT EXISTS (SELECT 1 FROM users WHERE admin = #{yes})
    SQL
  end

  # Nothing to undo: AddAdminToUsers's own rollback removes the column.
  def down; end
end
```

- [ ] **Step 4: Migrate, then regenerate the schema map**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails db:migrate
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails schema:map
git diff --stat db/schema.rb docs/schema-map.html
```

Expected: `db/schema.rb` gains `t.boolean "admin", default: false, null: false` in `users` and
`version: 2026_10_21_120100`, and nothing else. If anything else moved, the dev DB drifted: revert
that hunk by hand.

- [ ] **Step 5: Run the test**

```bash
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/models/mark_oldest_account_admin_migration_test.rb test/schema_map_test.rb
```

Expected: PASS. **Mutation-check:** drop `WHERE email <> #{demo}` → the demo test goes red; drop the
`NOT EXISTS` line → the re-run test goes red. Restore with `git checkout --` only after committing,
or by hand; clear `tmp/cache/bootsnap*` after an equal-length restore.

- [ ] **Step 6: Commit**

---

### Task 2: The predicate on `User`

**Files:**
- Modify: `app/models/user.rb` (after `normalizes :email`)
- Create: `test/models/user_admin_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

# WHO MAY MANAGE ACCOUNTS. `admin` is the stored flag; `can_manage_accounts?` is the answer every
# caller asks, and the shared demo account never gets a yes whatever its row says.
class UserAdminTest < ActiveSupport::TestCase
  setup do
    @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
    ENV.delete("DEMO_ACCOUNT_EMAIL")
  end

  teardown { @prior_demo ? ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo : ENV.delete("DEMO_ACCOUNT_EMAIL") }

  def account!(email, admin: false)
    User.create!(email:, admin:, confirmed_at: Time.current, omniauth_signup: true)
  end

  test "a new account is not an admin unless a door says so" do
    assert_not account!("plain@example.com").admin?
  end

  test "an admin manages accounts and a plain account does not" do
    assert account!("a@example.com", admin: true).can_manage_accounts?
    assert_not account!("b@example.com").can_manage_accounts?
  end

  test "the demo account never manages accounts, whatever its row says" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    demo = account!("demo@example.com", admin: true)

    assert demo.admin?, "the stored flag is set"
    assert_not demo.can_manage_accounts?
    assert_not_includes User.account_managers, demo
  end

  test "the last account manager is the only admin left, the demo not counting" do
    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    admin = account!("admin@example.com", admin: true)
    account!("demo@example.com", admin: true)
    account!("plain@example.com")

    assert admin.last_account_manager?

    second = account!("second@example.com", admin: true)
    assert_not admin.last_account_manager?
    assert_not second.last_account_manager?
  end

  test "a plain account is never the last account manager" do
    assert_not account!("plain@example.com").last_account_manager?
  end
end
```

- [ ] **Step 2: Run it; expect NoMethodError on `can_manage_accounts?`**

- [ ] **Step 3: Add to `app/models/user.rb`, directly after `normalizes :email, …`**

```ruby
  # WHO MAY MANAGE ACCOUNTS (Settings → Users; docs/superpowers/specs/2026-10-21-admin-users-design.md).
  # `admin` is the stored flag; this is the ANSWER, and the shared demo account never gets a yes
  # whatever its row says, because strangers are signed into it by one click (Tinkerex::Demo). The
  # Users gate, the Settings hub row and the last-admin count all ask this, never `admin?` alone.
  def can_manage_accounts? = admin? && !Tinkerex::Demo.demo?(self)

  # The accounts `can_manage_accounts?` says yes to, as a query. The demo's address is excluded by
  # value; with no demo configured `email <> ''` excludes nobody, since an email is never blank.
  scope :account_managers, -> { where(admin: true).where.not(email: Tinkerex::Demo.email.to_s) }

  # The only account left that can manage accounts. A count, not a lock: two admins acting in the
  # same instant can both pass it -- recorded in the design, and `tinkerex:admin` repairs a server
  # left with none.
  def last_account_manager? = can_manage_accounts? && !User.account_managers.where.not(id:).exists?
```

- [ ] **Step 4: Run; expect PASS.** Mutation-check: drop `&& !Tinkerex::Demo.demo?(self)` → the demo
  test goes red; drop `.where.not(email: …)` from the scope → the last-manager test goes red.

- [ ] **Step 5: Commit**

---

### Task 3: The doors that make an admin

**Files:**
- Modify: `app/controllers/users/registrations_controller.rb` (`build_resource`)
- Modify: `lib/tasks/tinkerex.rake` (`owner`; new `admin`)
- Modify: `test/integration/web/registration_mode_test.rb`, `test/tasks/tinkerex_tasks_test.rb`

- [ ] **Step 1: Failing tests.** In `registration_mode_test.rb`, after the "the first account is confirmed
  without mail…" test:

```ruby
    # THE FIRST ACCOUNT IS THE ADMIN, AND NO LATER SIGN-UP CAN ASK TO BE ONE: Devise's sign_up_params
    # permits email and the two passwords only, so a forged user[admin] is dropped.
    test "the first account is the admin; a later sign-up is not, even when it asks to be" do
      sign_up("owner@example.com")
      assert User.find_by!(email: "owner@example.com").admin?, "the owner manages accounts"

      delete destroy_user_session_path
      ENV["REGISTRATION"] = "open"
      post user_registration_path, params: { user: { email: "second@example.com", password: PASSWORD,
                                                     password_confirmation: PASSWORD, admin: "1" } }

      assert_not User.find_by!(email: "second@example.com").admin?
    end
```

  In `tinkerex_tasks_test.rb`: add `Rake::Task["tinkerex:admin"].reenable` to `setup`, and:

```ruby
  test "owner makes the first account an admin and a later one not" do
    User.delete_all
    invoke!("tinkerex:owner", "first@example.com")
    invoke!("tinkerex:owner", "second@example.com")

    assert User.find_by!(email: "first@example.com").admin?
    assert_not User.find_by!(email: "second@example.com").admin?
  end

  test "admin makes an existing account an admin" do
    u = User.create!(email: "promote@example.com", password: PASSWORD, confirmed_at: Time.current)

    capture_io { invoke!("tinkerex:admin", "promote@example.com") }

    assert u.reload.admin?
  end

  test "admin refuses a blank address, an unknown one and the demo account" do
    assert_raises(SystemExit) { capture_io { invoke!("tinkerex:admin") } }
    assert_raises(SystemExit) { capture_io { invoke!("tinkerex:admin", "nobody@example.com") } }

    ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
    demo = User.create!(email: "demo@example.com", password: PASSWORD, confirmed_at: Time.current)
    err = assert_raises(SystemExit) { capture_io { invoke!("tinkerex:admin", "demo@example.com") } }

    assert_match(/demo/, err.message)
    assert_not demo.reload.admin?
  end
```

- [ ] **Step 2: Run; expect the four to fail.**

- [ ] **Step 3: `build_resource` in `Users::RegistrationsController`:**

```ruby
    # The first account is the owner: confirmed on the spot, because a self-hoster has no mail server
    # on day one (Devise's own create path then signs a confirmed account straight in), and the admin
    # who manages every account after it at Settings → Users. Both must be set BEFORE save, which is
    # why this hooks build_resource rather than an after_create -- and why the admin flag is decided
    # here rather than in a User callback, which would also make the demo account (minted alone by
    # Tinkerex::DemoReset) and every test's first user an admin. Protected, as Devise's own is: a
    # public method on a controller is an action.
    def build_resource(hash = {})
      super
      return unless Tinkerex::Registration.first_owner?

      resource.skip_confirmation!
      resource.admin = true
    end
```

- [ ] **Step 4: `lib/tasks/tinkerex.rake`.** In `owner`, the create becomes:

```ruby
    # The first account is the admin (Settings → Users), as the sign-up form's is.
    user = User.create!(email:, password: pw, confirmed_at: Time.current, admin: first)
```

  …and after the `password` task:

```ruby
  # THE RECOVERY DOOR for a server with no admin: one whose only accounts came from single sign-on
  # (User.from_omniauth is not an admin door -- the provider decides who signs in, not who
  # administers), or one restored from before admins existed with its oldest account gone.
  desc "Make an account an admin: bin/rails tinkerex:admin[EMAIL]"
  task :admin, [ :email ] => :environment do |_t, args|
    email = args[:email].to_s.strip.downcase
    abort "usage: bin/rails tinkerex:admin[EMAIL]" if email.blank?
    u = User.find_by(email:) or abort "no account #{email.inspect}"
    # Strangers are signed into the demo by one click; User#can_manage_accounts? ignores its flag.
    abort "#{email} is the shared demo account (DEMO_ACCOUNT_EMAIL) and cannot be an admin" if Tinkerex::Demo.demo?(u)
    u.update!(admin: true)
    puts "#{email} is an admin"
  end
```

  Also update the file's header comment: "Console doors for a server with no mail" → name admin.

- [ ] **Step 5: Run; expect PASS.** Mutation-check: drop `resource.admin = true` → red; drop
  `admin: first` → red; drop the demo `abort` → red.

- [ ] **Step 6: Commit**

---

### Task 4: Settings → Users

**Files:**
- Modify: `config/routes.rb` (inside `namespace :settings`, after `resource :handle`)
- Create: `app/controllers/settings/users_controller.rb`
- Create: `app/views/settings/users/index.html.erb`, `app/views/settings/users/edit.html.erb`
- Modify: `app/controllers/settings_controller.rb`, `app/views/settings/show.html.erb`
- Modify: `app/assets/stylesheets/pages/settings.css`
- Create: `test/integration/web/settings_users_test.rb`
- Modify: `test/integration/web/settings_hub_test.rb`, `test/integration/web/template_hygiene_test.rb`

- [ ] **Step 1: Routes**

```ruby
    # ACCOUNTS (2026-10-21): an admin lists and adds accounts on the index, and changes one on its own
    # page (`edit`), which the three member actions post from. No `show` and no `update`: each change
    # has its own door and its own words (Settings::UsersController).
    resources :users, only: %i[index create edit destroy] do
      member do
        patch :reset_password
        patch :set_admin
      end
    end
```

- [ ] **Step 2: The integration test (write it whole; it fails on the missing route/controller)**

```ruby
require "test_helper"

module Web
  # SETTINGS → USERS (2026-10-21; docs/superpowers/specs/2026-10-21-admin-users-design.md): an admin
  # adds accounts, and on each other account's page resets its password, makes or unmakes it an
  # admin, or deletes it.
  #
  # EVERY TEST RUNS ON ALL THREE BACKEND LEGS AND BRANCHES, NEVER SKIPS (§15). Two things differ by
  # backend and both are asked of the CAPABILITY, never of the LIBRARY_BACKEND name: whether a new
  # account's scan is queued (`scannable?`) and what the page says a new account sees (`syncable?`).
  #
  # The forms' rendered field names are asserted before any request that posts them (§14d: a test
  # that posts a Ruby hash proves nothing about a field the page names differently).
  class SettingsUsersTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze
    NEW_PASSWORD = "a brand new horse battery".freeze

    setup do
      @prior_demo = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV.delete("DEMO_ACCOUNT_EMAIL")
      @admin = User.create!(email: "admin@example.com", password: PASSWORD, confirmed_at: Time.current, admin: true)
      @member = User.create!(email: "member@example.com", password: PASSWORD, confirmed_at: Time.current)
    end

    teardown { @prior_demo ? ENV["DEMO_ACCOUNT_EMAIL"] = @prior_demo : ENV.delete("DEMO_ACCOUNT_EMAIL") }

    def sign_in_as(user) = sign_in_web!(user, password: PASSWORD)

    def caps = FileLayer.current.capabilities

    # Every action, as the real forms send it. Each is refused for a non-admin before it reads params.
    def every_request(target)
      [
        -> { get settings_users_path },
        -> { post settings_users_path, params: { user: { email: "x@example.com", password: NEW_PASSWORD } } },
        -> { get edit_settings_user_path(target) },
        -> { patch reset_password_settings_user_path(target), params: { user: { password: NEW_PASSWORD } } },
        -> { patch set_admin_settings_user_path(target), params: { admin: "1" } },
        -> { delete settings_user_path(target), params: { confirm_email: target.email } }
      ]
    end

    # ============================================================ who reaches it

    test "a plain account is sent back to Settings from every action, and nothing changes" do
      sign_in_as(@member)

      every_request(@admin).each do |request|
        assert_no_difference -> { User.count } do
          request.call
        end
        assert_redirected_to settings_path
        assert_equal "Only an admin can manage accounts.", flash[:alert]
      end
      assert @admin.reload.valid_password?(PASSWORD)
      assert_not @member.reload.admin?
    end

    # Its row says admin, and that is exactly the state this proves cannot reach the page.
    test "the demo account is sent back to Settings even with the admin flag set" do
      ENV["DEMO_ACCOUNT_EMAIL"] = "demo@example.com"
      demo = User.create!(email: "demo@example.com", password: PASSWORD, confirmed_at: Time.current, admin: true)
      sign_in_as(demo)

      every_request(@member).each do |request|
        request.call
        assert_redirected_to settings_path
      end
      assert User.exists?(@member.id)
      assert @member.reload.valid_password?(PASSWORD)
    end

    test "the Settings hub shows the Users row to an admin only" do
      sign_in_as(@admin)
      get settings_path
      assert_select "ul.settings-hub a.settings-name[href=?]", settings_users_path, text: "Users"
      assert_select ".settings-fact", text: "2 accounts"

      delete destroy_user_session_path
      sign_in_as(@member)
      get settings_path
      assert_select "a[href=?]", settings_users_path, count: 0
    end

    # ============================================================ the list and the add form

    test "the list links each other account to its page and the signed-in one to the Account page" do
      sign_in_as(@admin)
      get settings_users_path

      assert_response :success
      assert_select "ul.settings-list li", count: 2
      assert_select "a.settings-name[href=?]", edit_user_registration_path, text: @admin.email
      assert_select "a.settings-name[href=?]", edit_settings_user_path(@member), text: @member.email
      assert_select "a[href=?]", edit_settings_user_path(@admin), count: 0
      assert_select ".settings-fact", text: "you"
      assert_select ".settings-fact", text: "admin", count: 1
      assert_select ".settings-fact", text: "never signed in", count: 1
    end

    test "the page says what a new account will see" do
      sign_in_as(@admin)
      get settings_users_path

      if caps.syncable?
        assert_match(/a library of its own/, response.body)
      else
        assert_match(/sees the same library folder/, response.body)
      end
    end

    test "the add form names the fields the controller reads" do
      sign_in_as(@admin)
      get settings_users_path

      assert_select "form[action=?][method=post]", settings_users_path do
        assert_select "input[type=email][name=?]", "user[email]"
        # Visible text: the admin reads it out or pastes it to the person.
        assert_select "input[type=text][name=?]", "user[password]"
        assert_select "input[type=checkbox][name=?][value=?]", "user[admin]", "1"
      end
    end

    test "adding an account makes a confirmed account that signs in, sends no mail, and queues its scan where the library is scanned" do
      sign_in_as(@admin)

      assert_emails 0 do
        post settings_users_path, params: { user: { email: " New@Example.com ", password: NEW_PASSWORD, admin: "0" } }
      end

      assert_redirected_to settings_users_path
      created = User.find_by!(email: "new@example.com")
      assert created.confirmed?
      assert_not created.admin?
      scans = enqueued_jobs.select { |j| j[:job] == Library::ScanJob }.map { |j| j[:args].first["user_id"] }
      assert_equal(caps.scannable? ? [ created.id ] : [], scans)

      delete destroy_user_session_path
      sign_in_web!(created, password: NEW_PASSWORD)
    end

    test "the admin box makes the new account an admin" do
      sign_in_as(@admin)
      post settings_users_path, params: { user: { email: "second-admin@example.com", password: NEW_PASSWORD, admin: "1" } }

      assert User.find_by!(email: "second-admin@example.com").can_manage_accounts?
    end

    test "a taken address, a short password and a blank one re-render the form with the reason" do
      sign_in_as(@admin)
      cases = {
        { email: @member.email, password: NEW_PASSWORD } => /already been taken/,
        { email: "short@example.com", password: "short" } => /too short/,
        { email: "blank@example.com", password: "" } => /can't be blank/
      }

      cases.each do |fields, reason|
        assert_no_difference -> { User.count } do
          post settings_users_path, params: { user: fields }
        end
        assert_response :unprocessable_entity
        assert_select ".form-errors", text: reason
        assert_select "input[name=?][value=?]", "user[email]", fields[:email]
      end
    end

    # ============================================================ one account's page

    test "the account page names the fields its three forms send" do
      sign_in_as(@admin)
      get edit_settings_user_path(@member)

      assert_response :success
      assert_select "form[action=?]", reset_password_settings_user_path(@member) do
        assert_select "input[name=?][value=?]", "_method", "patch"
        assert_select "input[type=text][name=?]", "user[password]"
      end
      assert_select "form[action=?]", set_admin_settings_user_path(@member) do
        assert_select "input[name=?][value=?]", "admin", "1"
      end
      assert_select "form[action=?]", settings_user_path(@member) do
        assert_select "input[name=?][value=?]", "_method", "delete"
        assert_select "input[type=text][name=?]", "confirm_email"
      end
    end

    test "every action on the signed-in account goes to the Account page and changes nothing" do
      sign_in_as(@admin)

      every_request(@admin).drop(2).each do |request|
        request.call
        assert_redirected_to edit_user_registration_path
      end
      @admin.reload
      assert @admin.valid_password?(PASSWORD)
      assert @admin.admin?
    end

    test "a reset sets the new password, ends the old one, confirms and unlocks" do
      @member.update_columns(confirmed_at: nil, locked_at: Time.current, failed_attempts: 10)
      sign_in_as(@admin)

      patch reset_password_settings_user_path(@member), params: { user: { password: NEW_PASSWORD } }

      assert_redirected_to edit_settings_user_path(@member)
      @member.reload
      assert @member.valid_password?(NEW_PASSWORD)
      assert_not @member.valid_password?(PASSWORD)
      assert @member.confirmed?
      assert_not @member.access_locked?
      assert_equal 0, @member.failed_attempts

      delete destroy_user_session_path
      sign_in_web!(@member, password: NEW_PASSWORD)
    end

    # A passwordless (single sign-on) account answers password_required? false, so without the
    # controller's own check a blank reset would save as a silent no-op and report success.
    test "a reset refuses a blank or short password, for a passwordless account too" do
      sso = User.create!(email: "sso@example.com", confirmed_at: Time.current, omniauth_signup: true)
      sign_in_as(@admin)

      [ [ @member, "" ], [ @member, "short" ], [ sso, "" ] ].each do |user, password|
        patch reset_password_settings_user_path(user), params: { user: { password: } }
        assert_response :unprocessable_entity
        assert_select ".form-errors"
      end
      assert @member.reload.valid_password?(PASSWORD)
      assert sso.reload.encrypted_password.blank?
    end

    test "make and remove admin; the demo account cannot be made one" do
      sign_in_as(@admin)

      patch set_admin_settings_user_path(@member), params: { admin: "1" }
      assert_redirected_to edit_settings_user_path(@member)
      assert @member.reload.admin?

      patch set_admin_settings_user_path(@member), params: { admin: "0" }
      assert_not @member.reload.admin?

      ENV["DEMO_ACCOUNT_EMAIL"] = @member.email
      patch set_admin_settings_user_path(@member), params: { admin: "1" }
      assert_not @member.reload.admin?
      assert_match(/demo/, flash[:alert].to_s)
    end

    test "deleting needs the account's address typed, then removes it and what it owns" do
      project = @member.maker_projects.create!(name: "Theirs", status: "active")
      sign_in_as(@admin)

      assert_no_difference -> { User.count } do
        delete settings_user_path(@member), params: { confirm_email: "wrong@example.com" }
      end
      assert_response :unprocessable_entity
      assert_select ".form-errors", text: /Type member@example.com/

      delete settings_user_path(@member), params: { confirm_email: " MEMBER@example.com " }

      assert_redirected_to settings_users_path
      assert_not User.exists?(@member.id)
      assert_not Maker::Project.exists?(project.id)
      assert User.exists?(@admin.id)
    end
  end
end
```

- [ ] **Step 3: The controller, `app/controllers/settings/users_controller.rb`**

```ruby
# ACCOUNTS, FOR AN ADMIN (2026-10-21; docs/superpowers/specs/2026-10-21-admin-users-design.md). The
# browser twin of the console doors in lib/tasks/tinkerex.rake: list every account, add one confirmed
# with a password the admin types, and on each other account's page reset its password, make or
# unmake it an admin, or delete it.
#
# EVERY ACCOUNT ON THE SERVER, NOT current_user's OWN ROWS: the one controller whose subject is other
# accounts, which is why its lookups are User.find and the gate comes first. A non-admin -- and the
# shared demo, whatever its row says (User#can_manage_accounts?) -- is sent back to Settings.
#
# NEVER THE SIGNED-IN ACCOUNT. Your password, your address and your deletion are the Account page's,
# behind your current password (Users::RegistrationsController); every member action here sends you
# there. That is also what keeps an admin on the server: the one acting always remains one, so
# demoting or deleting another account can never remove the last. The only door that could is the
# Account page's own delete, which refuses it.
module Settings
  class UsersController < ApplicationController
    before_action :require_account_manager!
    before_action :set_user, only: %i[edit reset_password set_admin destroy]

    def index
      @users = User.order(:id).to_a
      @new_user = User.new
    end

    # POST /settings/users {user: {email, password, admin}}. Confirmed on the spot, as tinkerex:owner
    # does: the admin chose this person, and a self-hosted server usually has no mail to confirm by.
    def create
      @new_user = User.new(new_user_params.merge(confirmed_at: Time.current))
      if refuse_blank_password(@new_user, new_user_params[:password]) && @new_user.save
        # ON A SCANNABLE BACKEND (share, s3) EACH ACCOUNT HOLDS ITS OWN CATALOG OF THE ONE LIBRARY,
        # filled by Library::ScanJob per user, so without this the new account opens an empty library
        # until the next 15-minute sweep. No pending check: this page sits behind
        # require_library_folder!, so the folder is confirmed by construction.
        Library::ScanJob.enqueue_for(@new_user) if capabilities.scannable?
        redirect_to settings_users_path, status: :see_other,
                    notice: "Added #{@new_user.email}. Give them the password you set."
      else
        @users = User.order(:id).to_a
        render :index, status: :unprocessable_entity
      end
    end

    def edit; end

    # PATCH /settings/users/:id/reset_password {user: {password}}. Also confirms the account and
    # clears a lock, since a locked-out person is the usual reason to be here. Devise keeps the
    # password's salt in the session, so the account's other browser sessions end; its desktop
    # devices keep their tokens, which the page says.
    def reset_password
      password = params.require(:user)[:password].to_s
      @user.assign_attributes(password:, locked_at: nil, failed_attempts: 0, unlock_token: nil)
      @user.confirmed_at ||= Time.current
      if refuse_blank_password(@user, password) && @user.save
        redirect_to edit_settings_user_path(@user), status: :see_other, notice: "New password set for #{@user.email}."
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # PATCH /settings/users/:id/set_admin {admin: "1"|"0"}: the state asked for, not a toggle, so a
    # double submit is harmless. The demo account is refused rather than flagged -- the flag would be
    # ignored (User#can_manage_accounts?), and a page reading "admin" over it would mislead.
    # `update_column`, not `update!`: a flag flip must not fail on an unrelated validation of an old row.
    def set_admin
      admin = params[:admin] == "1"
      if admin && Tinkerex::Demo.demo?(@user)
        return redirect_to edit_settings_user_path(@user), status: :see_other,
                           alert: "#{@user.email} is the shared demo account and cannot be an admin."
      end

      @user.update_column(:admin, admin)
      redirect_to edit_settings_user_path(@user), status: :see_other,
                  notice: admin ? "#{@user.email} is now an admin." : "#{@user.email} is no longer an admin."
    end

    # DELETE /settings/users/:id {confirm_email}. The account's whole cascade (User's dependent: list,
    # kept complete by test/models/tenant_cleanup_test.rb), so the admin types its address first.
    # Files in the library are not part of it.
    def destroy
      unless params[:confirm_email].to_s.strip.downcase == @user.email
        @confirm_error = "Type #{@user.email} exactly to delete this account."
        return render :edit, status: :unprocessable_entity
      end

      @user.destroy!
      redirect_to settings_users_path, status: :see_other, notice: "Deleted #{@user.email}."
    end

    private

    def require_account_manager!
      return if current_user.can_manage_accounts?

      redirect_to settings_path, alert: "Only an admin can manage accounts.", status: :see_other
    end

    def set_user
      @user = User.find(params[:id])
      return unless @user == current_user

      redirect_to edit_user_registration_path, status: :see_other,
                  alert: "Your own account is changed here, behind your current password."
    end

    def new_user_params = params.require(:user).permit(:email, :password, :admin)

    # A BLANK PASSWORD IS REFUSED HERE, NOT LEFT TO DEVISE: User#password_required? answers false when
    # there is neither a password nor a digest (the single sign-on seam), so a blank one would make a
    # new account nobody can sign in to, or "reset" a passwordless account to nothing, and report
    # success either way. True when the password may go on to validation.
    def refuse_blank_password(user, password)
      return true if password.to_s.present?

      user.errors.add(:password, :blank)
      false
    end
  end
end
```

- [ ] **Step 4: `app/views/settings/users/index.html.erb`**

```erb
<% content_for :title, "Users — Tinkerex" %>

<%# ACCOUNTS, FOR AN ADMIN (Settings::UsersController). The list, then the add form, whose button is
    the page's one accent (design-system.md rule 13). The signed-in row links to the Account page,
    never to a page here: your own account is changed there, behind your password. %>
<div class="page-head">
  <h1>Users</h1>
  <%= link_to "Settings", settings_path, class: "btn ghost small" %>
</div>

<p class="muted">
  <% if capabilities.syncable? %>
    Each account has a library of its own on the sync server, made the first time it is used.
  <% else %>
    Every account on this server sees the same library folder, and can open, change and delete every
    file in it. Add only people you would hand the folder to.
  <% end %>
</p>

<ul class="settings-list">
  <% @users.each do |user| %>
    <li>
      <% if user == current_user %>
        <%= link_to user.email, edit_user_registration_path, class: "settings-name" %>
        <span class="settings-fact">you</span>
      <% else %>
        <%= link_to user.email, edit_settings_user_path(user), class: "settings-name" %>
      <% end %>
      <% if user.can_manage_accounts? %>
        <span class="settings-fact">admin</span>
      <% end %>
      <span class="settings-fact"><%= user.last_sign_in_at ? "signed in #{time_ago_in_words(user.last_sign_in_at)} ago" : "never signed in" %></span>
    </li>
  <% end %>
</ul>

<h2>Add an account</h2>
<% if @new_user.errors.any? %>
  <div class="form-errors" role="alert"><%= @new_user.errors.full_messages.to_sentence %>.</div>
<% end %>
<%# scope: :user -- form_with url: has no model object here, so scope: is what names the fields
    user[email], user[password] and user[admin], which Settings::UsersController#new_user_params
    requires (CLAUDE.md §14d). The password is visible text: the admin reads it out or pastes it. %>
<%= form_with url: settings_users_path, scope: :user, class: "settings-add" do |f| %>
  <label>
    <span>Email</span>
    <%= f.email_field :email, value: @new_user.email, required: true, autocomplete: "off" %>
  </label>
  <label>
    <span>Password</span>
    <%= f.text_field :password, required: true, minlength: Devise.password_length.min,
                     autocomplete: "new-password", spellcheck: false %>
  </label>
  <label>
    <span>Admin</span>
    <%= f.check_box :admin %>
  </label>
  <%= f.submit "Add account", class: "btn primary" %>
<% end %>
```

- [ ] **Step 5: `app/views/settings/users/edit.html.erb`**

```erb
<% content_for :title, "#{@user.email} — Users — Tinkerex" %>

<%# ONE ACCOUNT, FOR AN ADMIN (Settings::UsersController): reset its password, make or unmake it an
    admin, delete it. Never the signed-in account, which set_user sends to the Account page. "Set
    password" is the accent (design-system.md rule 13); Delete is the danger button, behind a typed
    address rather than a click-through confirm, because it cannot be undone. %>
<div class="page-head">
  <h1><%= @user.email %></h1>
  <%= link_to "Users", settings_users_path, class: "btn ghost small" %>
</div>

<p class="muted">
  <%= @user.can_manage_accounts? ? "An admin." : "Not an admin." %>
  <%= @user.last_sign_in_at ? "Last signed in #{time_ago_in_words(@user.last_sign_in_at)} ago." : "Has never signed in." %>
  <%= "Locked after too many wrong passwords." if @user.access_locked? %>
</p>

<section class="user-manage">
  <h2>Reset the password</h2>
  <% if @user.errors.any? %>
    <div class="form-errors" role="alert"><%= @user.errors.full_messages.to_sentence %>.</div>
  <% end %>
  <p class="muted">Signs <%= @user.email %> out of every browser and unlocks the account. A desktop app
    already signed in keeps syncing.</p>
  <%# scope: :user, for the reason the add form gives: the field must be user[password]. %>
  <%= form_with url: reset_password_settings_user_path(@user), method: :patch, scope: :user, class: "settings-add" do |f| %>
    <label>
      <span>New password</span>
      <%= f.text_field :password, required: true, minlength: Devise.password_length.min,
                       autocomplete: "new-password", spellcheck: false %>
    </label>
    <%= f.submit "Set password", class: "btn primary" %>
  <% end %>
</section>

<section class="user-manage">
  <h2>Admin</h2>
  <% if @user.can_manage_accounts? %>
    <p class="muted">Can add, change and delete accounts on the Users page.</p>
    <%= button_to "Remove admin", set_admin_settings_user_path(@user), method: :patch,
                  params: { admin: "0" }, class: "btn" %>
  <% elsif Tinkerex::Demo.demo?(@user) %>
    <p class="muted">The shared demo account cannot be an admin.</p>
  <% else %>
    <p class="muted">An admin can add, change and delete accounts on the Users page.</p>
    <%= button_to "Make admin", set_admin_settings_user_path(@user), method: :patch,
                  params: { admin: "1" }, class: "btn" %>
  <% end %>
</section>

<section class="user-manage">
  <h2>Delete this account</h2>
  <p>Removes <%= @user.email %> and everything it has in Tinkerex: its projects, tasks, notes, tags,
    pins, previews and its copy of the library catalog. Every file in the library stays where it is.
    <% if capabilities.syncable? %>Its library on the sync server is not removed.<% end %>
    This cannot be undone.</p>
  <% if @confirm_error %>
    <div class="form-errors" role="alert"><%= @confirm_error %></div>
  <% end %>
  <%# No scope: the field is the flat `confirm_email` #destroy reads, and a plain text_field on a
      blank object_name emits exactly that (CLAUDE.md §14d: only fields_for interpolates brackets). %>
  <%= form_with url: settings_user_path(@user), method: :delete, class: "settings-add" do |f| %>
    <label>
      <span>Type <%= @user.email %> to confirm</span>
      <%= f.text_field :confirm_email, required: true, autocomplete: "off", spellcheck: false %>
    </label>
    <%= f.submit "Delete account", class: "btn danger" %>
  <% end %>
</section>
```

- [ ] **Step 6: The hub row.** `SettingsController#show` gains
  `@user_count = User.count if current_user.can_manage_accounts?`; `settings/show.html.erb` gains,
  before the Account row:

```erb
  <% if current_user.can_manage_accounts? %>
    <li>
      <%= link_to "Users", settings_users_path, class: "settings-name" %>
      <span class="settings-fact"><%= pluralize(@user_count, "account") %></span>
    </li>
  <% end %>
```

  And the controller's header comment names the Users row (admins only).

- [ ] **Step 7: CSS**, in `pages/settings.css` after the library block:

```css
  /* --- Users (2026-10-21): one account's page, three sections read top to bottom. --- */
  .user-manage { max-width: 640px; margin-top: var(--space-5); }
```

- [ ] **Step 8: The template sweep.** In `template_hygiene_test.rb` setup, the sweep user becomes
  `admin: true`, and a second account `@other_account` is created
  (`User.create!(email: "hygiene-other-…@example.com", confirmed_at: Time.current, omniauth_signup: true)`);
  the pages map gains `"settings/users" => settings_users_path` and
  `"settings/users edit" => edit_settings_user_path(@other_account)`.

- [ ] **Step 9: The hub test.** Add to `settings_hub_test.rb`: an admin's hub lists eight rows with
  "Users" before "Account". The existing seven-row test stays (its user is not an admin).

```ruby
    test "an admin's hub gains the Users row, before Account" do
      @user.update!(admin: true)
      get settings_path

      names = css_select("ul.settings-list.settings-hub li .settings-name").map { |el| el.text.strip }
      assert_equal [ "Library folder", "Shelves", "Suppliers", "Locations", "Tags", "Users", "Account", "Theme" ], names
    end
```

- [ ] **Step 10: Run all four test files; expect PASS.** Mutation-checks (each must go red, then restore):
  1. `require_account_manager!` → `return if true`: the plain-account and demo tests.
  2. `can_manage_accounts?` in the gate → `admin?`: the demo test.
  3. drop `set_user`'s self redirect: the signed-in-account test.
  4. drop `refuse_blank_password` from `reset_password`: the passwordless reset case.
  5. drop the `confirm_email` comparison: the delete test.
  6. drop the scan enqueue: the add test on share and s3 (it stays green on chunk_remote, correctly).
  7. drop `scope: :user` from the add form: the field-name test.

- [ ] **Step 11: Commit**

---

### Task 5: The Account page keeps the last admin

**Files:**
- Modify: `app/controllers/users/registrations_controller.rb` (`destroy`)
- Modify: `test/integration/web/account_settings_test.rb`

- [ ] **Step 1: Failing tests**

```ruby
    # --- the last admin --------------------------------------------------------

    test "the only admin cannot delete their account while other accounts exist" do
      @user.update!(admin: true)
      User.create!(email: "other@example.com", password: PASSWORD, confirmed_at: Time.current)

      assert_no_difference "User.count" do
        delete user_registration_path, params: { user: { current_password: PASSWORD } }
      end
      assert_response :unprocessable_entity
      assert_match(/only admin/, response.body)
    end

    test "an admin may delete their account when another admin remains" do
      @user.update!(admin: true)
      User.create!(email: "other@example.com", password: PASSWORD, confirmed_at: Time.current, admin: true)

      delete user_registration_path, params: { user: { current_password: PASSWORD } }

      assert_not User.exists?(@user.id)
    end

    test "the only account on a server may delete itself, admin or not" do
      @user.update!(admin: true)

      delete user_registration_path, params: { user: { current_password: PASSWORD } }

      assert_not User.exists?(@user.id)
    end
```

- [ ] **Step 2: In `Users::RegistrationsController`:** a constant beside `DEMO_ACCOUNT_REFUSAL`,

```ruby
    LAST_ADMIN_REFUSAL = "You are this server's only admin. Make another account an admin under " \
                         "Settings → Users before deleting yours.".freeze
```

  …and at the top of `#destroy`:

```ruby
      # THE LAST ADMIN STAYS WHILE ANYONE ELSE IS HERE (2026-10-21): accounts are managed at Settings →
      # Users by an admin, so deleting the only one leaves accounts nobody can manage but a console.
      # The only door that can: Settings::UsersController never acts on the signed-in account. Asked
      # before the password, because no password makes it right. The sole account may still go.
      if resource.last_account_manager? && User.where.not(id: resource.id).exists?
        resource.errors.add(:base, LAST_ADMIN_REFUSAL)
        clean_up_passwords(resource)
        set_minimum_password_length
        respond_with_navigational(resource) { render :edit, status: :unprocessable_entity }
        return
      end
```

- [ ] **Step 3: Run; expect PASS.** Mutation-check: drop the `if` block → the first test goes red;
  drop `&& User.where.not(id: resource.id).exists?` → the sole-account test goes red.

- [ ] **Step 4: Commit**

---

### Task 6: Docs

**Files:** `docs/INSTALL.md`, `app/views/help/show.html.erb`, `CLAUDE.md`

- [ ] **INSTALL.md §2 "First run":** the first account is the owner **and the admin**; "more accounts
  are added from the console (section 4)" → "an admin adds more under Settings → Users (section 4)".
- [ ] **INSTALL.md §4:** a new "**Adding an account.**" paragraph leads: Settings → Users, admins only —
  add (email, a password you pass on, optionally admin), and on an account's page reset its password
  (also unlocks it), make or remove admin, delete it (typed address; files stay). The first account
  is the admin; existing installs made their oldest account admin on update. The console section
  becomes "**From the console**", and gains `tinkerex:admin[EMAIL]` for a server with no admin.
  Keep `test/install_docs_test.rb` green (no env-var changes).
- [ ] **Help page** "For the person running this server" → Accounts: lead with "An admin adds accounts,
  resets passwords and grants admin under Settings → Users"; the console tasks follow. Check
  `test/integration/web/help_page_test.rb`'s assertions on that paragraph first.
- [ ] **CLAUDE.md §8**, the registration bullet: say the first account is the **admin** and admins add
  accounts at Settings → Users. **Line-neutral** — the file is at its 1,354-line ceiling
  (`test/docs_hygiene_test.rb`): rewrap within the bullet's existing lines.
- [ ] Run `test/install_docs_test.rb`, `test/docs_hygiene_test.rb`, `help_page_test.rb`. Commit.

---

### Task 7: Verify and open the PR

- [ ] `find . -name '* 2.*' -not -path './db/seeds/*'` is empty (macOS duplicates).
- [ ] Bare `bin/ci` in the background (it needs `../tinkerex-sync`); all gates green and the three backend
  legs' RUN counts equal.
- [ ] `git diff --stat origin/main -- app/ lib/ config/ db/` shows only this plan's files (no leftover
  mutation).
- [ ] `/finish-branch`: commit, push, `gh pr create` (body states what was verified and what was not),
  then `bin/log arc --from-pr <n>`.
