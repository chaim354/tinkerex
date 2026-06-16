# Devise Auth Migration + Device-Login Enrollment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-rolled human-identity web auth with **Devise**, and replace pairing-code device enrollment with **device-login** (email+password → device token, the Dropbox model), while keeping the entire `/v1/*` device-token sync machinery byte-for-byte unchanged.

**Architecture:** Two auth layers, sharply separated. (1) **Human identity** = Devise on the `User` model (`database_authenticatable, registerable, recoverable, rememberable, validatable, confirmable, lockable, trackable, timeoutable, omniauthable`), governing the server-rendered web UI and a single new JSON enrollment endpoint. (2) **Device identity** = the existing `Device` 256-bit bearer token, `Authentication` concern, ActionCable `?token=` auth, and all `/v1/*` sync endpoints — **untouched**. Account creation now happens only via Devise (web signup or `:registerable`); a **confirmed** Devise account is a precondition for enrolling a device. Device enrollment is a new `POST /v1/devices/login {email, password, device_name}` that authenticates credentials through Devise's own primitives (`find_for_authentication` + `valid_password?`, rejecting unconfirmed/locked accounts) and returns a device token. The pairing-code flow (`DevicePairing` model+table, `POST /v1/devices/pairing`, `POST /v1/auth/pair`) and the old `POST /v1/auth/register` device-bootstrap are removed.

**Tech Stack:** Rails 8.1, Devise 4.9.x (MIT), `omniauth` + `omniauth_openid_connect` (MIT) as the preserved OAuth seam, bcrypt (already present, MIT), SQLite (test/self-host) + Postgres (managed) — adapter-agnostic. The custom server-side `Session` model and `WebAuthentication` cookie scheme are **retired** in favor of Devise/Warden's session handling; the `Device`/`DevicePairing`/`Session` digest-at-rest hygiene that remains (Device, Session-for-trackable-not-needed) is preserved where still used.

**Licensing note (CLAUDE.md §9):** Devise is **MIT**, `omniauth` is **MIT**, `omniauth_openid_connect` is **MIT**, `omniauth-rails_csrf_protection` is **MIT**, bcrypt is **MIT**. All permissive — no GPL/AGPL introduced. Confirmed acceptable before adding to the Gemfile.

---

## Migration numbering note

The current schema high-water mark is `db/schema.rb` → `define(version: 2026_06_16_130001)`. The newest migration on disk is `20260616130001_create_maker_bom_lines.rb`. **Every new migration in this plan MUST have a version strictly greater than `20260616130001`.** This plan uses the contiguous block `20260617000001` … `20260617000006`, which sorts after the high-water mark on every platform. Do not renumber out of order; Devise's generator will try to timestamp with the current wall-clock date — **rename the generated migration files to the fixed `20260617*` numbers below** so the plan's commands and expected `schema.rb` diffs stay deterministic.

---

## Background: what exists today (read before starting)

- `app/models/user.rb` — `has_secure_password validations: false`; hand-rolled `generate_confirmation_token!`/`confirm!`/`find_by_confirmation_token`, `generate_reset_token!`/`find_by_reset_token`/`clear_reset_token!`, `confirmed?`/`confirmed` scope, and `User.from_omniauth` with the **`AccountLinkRefused`** anti-takeover guard. `next_seq!` (sync hot path) lives here too and **must not change**.
- `app/controllers/{sessions,registrations,confirmations,passwords,omniauth_callbacks}_controller.rb` — hand-rolled web auth controllers (server-rendered, redirect-based).
- `app/controllers/concerns/web_authentication.rb` — custom cookie/`Session`-row session; provides `current_user`, `logged_in?`, `require_login!`, `log_in`, `log_out`, and **`web_device`** (a stable per-user `Device` named `"web-session"` so the web UI uses the same per-user presign machinery).
- `app/controllers/concerns/authentication.rb` — **v1 Bearer device-token auth. DO NOT TOUCH.**
- `app/models/{session,user_identity,device,device_pairing}.rb`.
- `app/controllers/v1/{auth,devices,base}_controller.rb`; `app/mailers/user_mailer.rb` + `app/views/user_mailer/*`.
- `config/routes.rb` — web auth routes (lines 10–34) + `namespace :v1` (lines 60–64 hold `auth/register`, `auth/pair`, `devices`, `devices/pairing`).
- Tests: `test/integration/web/auth_flow_test.rb`, `test/models/user_auth_test.rb`, `test/models/device_pairing_test.rb`, `test/integration/v1/auth_test.rb`.
- `db/schema.rb` users table columns: `password_digest`, `confirmation_token_digest`, `confirmed_at`, `confirmation_sent_at`, `reset_token_digest`, `reset_sent_at`, `head_seq`, `email`.
- Rust client: `client/sync-client/src/lib.rs` `register`/`create_pairing`/`pair`/`create_device` (+ `RegisterResponse`/`PairingResponse`/`DeviceResponse`); usages across `client/sync-engine/{tests,examples}` and `client/maker-app/src-tauri/src/lib.rs`.

**Files the web file UI depends on (must keep working through the swap):** `app/controllers/files_controller.rb`, `app/controllers/trash_controller.rb` (and any others including `WebAuthentication`) call `current_user`, `require_login!`, and `web_device`. Devise provides `current_user`/`authenticate_user!`; we add a `web_device` helper to `ApplicationController` so those controllers keep working with a one-line rename (`require_login!` → `authenticate_user!`).

---

## File Structure

**Created:**
- `config/initializers/devise.rb` — Devise config (generated, then edited: mailer sender, `secret_key` left to credentials, OmniAuth strategies behind env, `confirm_within`, `maximum_attempts`/`unlock_strategy`, `timeout_in`).
- `app/views/devise/**` — Devise's server-rendered views (generated via `rails g devise:views`), restyled minimally to match the existing pages.
- `db/migrate/20260617000001_add_devise_to_users.rb` — add Devise columns (`encrypted_password`, `reset_password_token`, `reset_password_sent_at`, `remember_created_at`, `confirmation_token`, `unconfirmed_email`, `failed_attempts`, `unlock_token`, `locked_at`, `sign_in_count`, `current/last_sign_in_at`, `current/last_sign_in_ip`); add unique indexes for `reset_password_token`, `confirmation_token`, `unlock_token`.
- `db/migrate/20260617000002_backfill_devise_user_columns.rb` — data migration: copy `password_digest`→`encrypted_password`; `reset_token_digest`/`reset_sent_at` are dropped (Devise issues fresh tokens); confirmed users keep `confirmed_at`.
- `db/migrate/20260617000003_drop_legacy_user_auth_columns.rb` — drop `password_digest`, `confirmation_token_digest`, `confirmation_sent_at` *raw-digest* column, `reset_token_digest`, `reset_sent_at` (after backfill), and their indexes. **Keep `confirmed_at`** (Devise uses it). Keep `confirmation_sent_at` (Devise uses it — see note in Task 5).
- `db/migrate/20260617000004_drop_device_pairings.rb` — drop the `device_pairings` table.
- `app/controllers/users/sessions_controller.rb` — subclass `Devise::SessionsController` (custom redirects only if needed; default is fine).
- `app/controllers/users/registrations_controller.rb` — subclass `Devise::RegistrationsController`.
- `app/controllers/users/confirmations_controller.rb`, `app/controllers/users/passwords_controller.rb` — subclasses (default behavior; created for future hooks + explicit routing).
- `app/controllers/users/omniauth_callbacks_controller.rb` — Devise OmniAuth callbacks → `User.from_omniauth` (preserving `AccountLinkRefused`).
- `test/integration/web/devise_auth_flow_test.rb` — replaces `auth_flow_test.rb` (Devise paths/flows).
- `test/integration/v1/device_login_test.rb` — new device-login enrollment tests.

**Modified:**
- `Gemfile` — add `devise`, `omniauth`, `omniauth-rails_csrf_protection`, `omniauth_openid_connect`.
- `app/models/user.rb` — replace `has_secure_password` + hand-rolled token methods with `devise ...` module list; override `password_required?` for OmniAuth-only users; keep `from_omniauth` + `AccountLinkRefused`; **keep `next_seq!` verbatim**.
- `app/models/device.rb` — add `Device.login!(email:, password:, name:)` (or keep in controller; see Task 9). **`register!`/`authenticate`/`digest` unchanged.**
- `app/controllers/application_controller.rb` — add `web_device` helper; CSRF/Devise wiring.
- `app/controllers/v1/devices_controller.rb` — add `login` action (no Bearer auth required); `create`/`pairing` handling (drop `pairing`).
- `app/controllers/v1/auth_controller.rb` — **deleted** (or emptied) — `register`/`pair` removed.
- `config/routes.rb` — replace hand-rolled web auth routes with `devise_for :users` (+ controllers map + `:omniauthable` path guard); replace v1 `auth/register`/`auth/pair`/`devices/pairing` with `post "devices/login"`.
- Delete `app/controllers/{sessions,registrations,confirmations,passwords,omniauth_callbacks}_controller.rb`, `app/controllers/concerns/web_authentication.rb`, `app/models/session.rb`, `app/models/device_pairing.rb`, `app/mailers/user_mailer.rb` + views (Devise mailer replaces them).
- Files including `WebAuthentication` (`files_controller.rb`, `trash_controller.rb`, …) — swap `include WebAuthentication` → Devise (`before_action :authenticate_user!`) + keep `web_device`.
- `client/sync-client/src/lib.rs` — replace `register`/`pair`/`create_pairing` with `device_login(email, password, device_name)`.

**Deleted tests:** `test/models/device_pairing_test.rb`, `test/models/user_auth_test.rb` (token-lifecycle parts gone; `from_omniauth` parts move into a new `test/models/user_omniauth_test.rb`), `test/integration/web/auth_flow_test.rb`, `test/integration/v1/auth_test.rb` (pairing/register gone; replaced by `device_login_test.rb`).

---

## Task ordering & green-at-every-commit strategy

Devise is a large swap that cannot be done one column at a time while keeping the suite green, because the existing web-auth tests assert the *old* hand-rolled behavior. The strategy:

1. **Tasks 1–2 (additive):** add gems + Devise columns via migration. Suite stays green (nothing references the new columns yet).
2. **Task 3:** delete the old web-auth tests **and** the old web-auth controllers/routes/model in the *same commit*, replacing them with Devise routes/controllers/views and a new Devise test. The suite is green after this commit because old tests and old code are removed together and the new Devise test passes.
3. **Tasks 4–5:** model swap + passwordless-OAuth handling + OmniAuth tests.
4. **Tasks 6–7:** remove pairing (server) + add device-login (server), swapping the v1 tests in lockstep.
5. **Task 8:** drop legacy columns + `device_pairings` table.
6. **Task 9:** Rust client changes (specified as tasks; not gating the Rails suite).
7. **Task 10:** full-suite green gate.

Each task below ends at a green `bin/rails test` for the files it touches and a commit.

---

## Task 1: Add Devise + OmniAuth gems

**Files:**
- Modify: `Gemfile`
- Test: `test/models/devise_gem_smoke_test.rb` (temporary smoke test, removed in Task 3's cleanup is NOT needed — keep it; it's cheap)

- [ ] **Step 1: Write the failing test**

Create `test/models/devise_gem_smoke_test.rb`:

```ruby
require "test_helper"

# Confirms the Devise gem is loaded and its generator constant is available before we wire
# the model. Removed once `User` actually `devise`s (Task 4 supersedes this), but harmless.
class DeviseGemSmokeTest < ActiveSupport::TestCase
  test "Devise is loaded" do
    assert defined?(Devise), "Devise constant should be defined after bundling the gem"
  end

  test "OmniAuth is loaded" do
    assert defined?(OmniAuth), "OmniAuth constant should be defined after bundling the gem"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/models/devise_gem_smoke_test.rb`
Expected: FAIL — `NameError: uninitialized constant Devise` (gem not yet bundled).

- [ ] **Step 3: Add the gems**

Edit `Gemfile` — after the `bcrypt` block (currently lines 23–25), add:

```ruby
# Human-identity authentication (web login + device-login enrollment). Devise is MIT
# (CLAUDE.md §9). It governs ONLY the human layer; the v1 device-token machinery is
# untouched. OmniAuth keeps the OAuth/OIDC seam open (also MIT).
gem "devise", "~> 4.9"
gem "omniauth", "~> 2.1"
gem "omniauth-rails_csrf_protection", "~> 1.0"
gem "omniauth_openid_connect", "~> 0.8", require: false
```

- [ ] **Step 4: Bundle**

Run: `cd /tmp/tinkerex-devise-plan && bundle install`
Expected: `Bundle complete.` with `devise`, `omniauth`, `omniauth-rails_csrf_protection`, `omniauth_openid_connect` resolved. No license warnings (all MIT).

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/models/devise_gem_smoke_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 6: Commit**

```bash
cd /tmp/tinkerex-devise-plan
git add Gemfile Gemfile.lock test/models/devise_gem_smoke_test.rb
git commit -m "build(auth): add Devise + OmniAuth gems (MIT)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Install Devise + add Devise columns to users (additive migration)

**Files:**
- Create: `config/initializers/devise.rb` (generated)
- Create: `db/migrate/20260617000001_add_devise_to_users.rb`
- Modify: `db/schema.rb` (via `db:migrate`)
- Test: `test/models/devise_columns_test.rb`

- [ ] **Step 1: Generate the Devise install (initializer + locale only)**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails generate devise:install`
Expected: creates `config/initializers/devise.rb` and `config/locales/devise.en.yml`. The generator prints manual-setup instructions (root route, flash, mailer host) — we already have a root route and flash handling; the mailer default-url-options are set in Step 5.

- [ ] **Step 2: Write the failing test**

Create `test/models/devise_columns_test.rb`:

```ruby
require "test_helper"

# Verifies the Devise columns exist on `users` after the additive migration. At this point
# `User` does NOT yet call `devise` (Task 4), so we only check the schema.
class DeviseColumnsTest < ActiveSupport::TestCase
  COLUMNS = %w[
    encrypted_password reset_password_token reset_password_sent_at remember_created_at
    confirmation_token unconfirmed_email failed_attempts unlock_token locked_at
    sign_in_count current_sign_in_at last_sign_in_at current_sign_in_ip last_sign_in_ip
  ].freeze

  test "users has all Devise columns" do
    cols = User.column_names
    COLUMNS.each { |c| assert_includes cols, c, "users should have #{c}" }
  end

  test "confirmed_at is retained" do
    assert_includes User.column_names, "confirmed_at"
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/models/devise_columns_test.rb`
Expected: FAIL — `users should have encrypted_password` (columns not added yet).

- [ ] **Step 4: Write the migration**

Create `db/migrate/20260617000001_add_devise_to_users.rb` (note: `confirmable` adds `confirmation_token`, `confirmed_at`, `confirmation_sent_at`, `unconfirmed_email` — `confirmed_at` + `confirmation_sent_at` already exist, so only add the missing two):

```ruby
class AddDeviseToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users, bulk: true do |t|
      ## Database authenticatable (bcrypt; backfilled from password_digest in 000002)
      t.string :encrypted_password, null: false, default: ""

      ## Recoverable
      t.string   :reset_password_token
      t.datetime :reset_password_sent_at

      ## Rememberable
      t.datetime :remember_created_at

      ## Confirmable (confirmed_at + confirmation_sent_at already exist on the table)
      t.string :confirmation_token
      t.string :unconfirmed_email

      ## Lockable (unlock via email token; brute-force mitigation for device-login)
      t.integer  :failed_attempts, null: false, default: 0
      t.string   :unlock_token
      t.datetime :locked_at

      ## Trackable
      t.integer  :sign_in_count, null: false, default: 0
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string   :current_sign_in_ip
      t.string   :last_sign_in_ip
    end

    add_index :users, :reset_password_token, unique: true
    add_index :users, :confirmation_token,   unique: true
    add_index :users, :unlock_token,         unique: true
  end
end
```

- [ ] **Step 5: Configure the Devise initializer**

Edit `config/initializers/devise.rb`. Set the mailer sender and the new-capability options. Find and set these keys (they exist in the generated file as commented or default lines — change them to):

```ruby
  config.mailer_sender = "no-reply@tinkerex.app"

  # Confirmable: a sign-in is allowed for unconfirmed accounts only within this window?
  # We want STRICT confirmation (no grace period) to match today's "unconfirmed can't sign
  # in" gate. Leave allow_unconfirmed_access_for at 0 days (the default is 0.days here).
  config.allow_unconfirmed_access_for = 0.days
  # Re-confirmable: changing email re-triggers confirmation.
  config.reconfirmable = true

  # Lockable: lock after N failed attempts; unlock by emailed token or after a time window.
  config.lock_strategy   = :failed_attempts
  config.unlock_strategy = :both
  config.maximum_attempts = 10
  config.unlock_in        = 1.hour
  config.last_attempt_warning = true

  # Timeoutable: idle web sessions expire (does NOT affect device tokens).
  config.timeout_in = 2.weeks

  # Token hashing at rest: store only digests of confirmation/reset/unlock tokens (same
  # hygiene the hand-rolled flow had). Devise sends the raw token, stores the digest.
  config.token_generator_strategy = :secure if config.respond_to?(:token_generator_strategy)
```

Note: Devise 4.9 hashes reset/confirmation/unlock tokens at rest by default (`Devise.token_generator` + `Devise::Models::Confirmable` uses a digest comparison via `Devise.token_generator.digest`). The `:secure` line is defensive; if the key is unrecognized in the installed Devise, remove that single line — the default already digests.

Set the mailer default URL options for the test/dev/prod envs. In `config/environments/test.rb` add (inside the `Rails.application.configure do` block):

```ruby
  config.action_mailer.default_url_options = { host: "www.example.com" }
```

In `config/environments/development.rb` add:

```ruby
  config.action_mailer.default_url_options = { host: "localhost", port: 3000 }
```

(Production already configures `default_url_options` via `config.action_mailer.default_url_options`/host env in `config/environments/production.rb`; if absent, add `config.action_mailer.default_url_options = { host: ENV.fetch("APP_HOST", "localhost") }`.)

- [ ] **Step 6: Migrate**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails db:migrate`
Expected: `AddDeviseToUsers: migrated`. `db/schema.rb` now shows `define(version: 2026_06_17_000001)` and the new user columns/indexes.

- [ ] **Step 7: Run test to verify it passes**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/models/devise_columns_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 8: Verify the full suite is still green (additive change)**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test`
Expected: PASS — same count as before plus the 2 new column tests + 2 smoke tests. (The old `User.create!(email:, password:)` calls still work because `has_secure_password` is still on the model and `encrypted_password` has a default of `""`.)

- [ ] **Step 9: Commit**

```bash
cd /tmp/tinkerex-devise-plan
git add config/initializers/devise.rb config/locales/devise.en.yml \
        db/migrate/20260617000001_add_devise_to_users.rb db/schema.rb \
        config/environments/test.rb config/environments/development.rb \
        config/environments/production.rb test/models/devise_columns_test.rb
git commit -m "feat(auth): install Devise, add Devise columns to users (additive)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Swap web auth to Devise (controllers, routes, views) + replace web auth tests

This is the big lockstep swap for the **web** layer. The `User` model still has `has_secure_password` after this task (Task 4 swaps the model); to make Devise authenticate against the existing bcrypt hashes *now*, we backfill `encrypted_password` first.

**Files:**
- Create: `db/migrate/20260617000002_backfill_devise_user_columns.rb`
- Modify: `app/models/user.rb` (add a temporary `devise` call alongside — see note), `config/routes.rb`, `app/controllers/application_controller.rb`
- Create: `app/controllers/users/{sessions,registrations,confirmations,passwords}_controller.rb`, Devise views
- Delete: `app/controllers/{sessions,registrations,confirmations,passwords,omniauth_callbacks}_controller.rb`, `app/controllers/concerns/web_authentication.rb`, `app/models/session.rb`, `app/mailers/user_mailer.rb` + `app/views/user_mailer/*`, `test/integration/web/auth_flow_test.rb`
- Create: `test/integration/web/devise_auth_flow_test.rb`

> **Sequencing within this task:** because it deletes old code and old tests together and adds new code and new tests together, the suite is only asserted green at the **end** of the task (Step 14). Intermediate steps will not individually pass — that is expected and explicitly noted.

- [ ] **Step 1: Backfill migration (copy bcrypt hash into Devise's column)**

Create `db/migrate/20260617000002_backfill_devise_user_columns.rb`:

```ruby
# Copy the existing has_secure_password bcrypt digest (password_digest) into Devise's
# encrypted_password column. Both are bcrypt with the same internal format, so existing
# confirmed users authenticate against Devise unchanged — no password reset required.
# Rows with a NULL/blank password_digest (OmniAuth-only accounts) keep the "" default,
# which bcrypt will never match — exactly the passwordless behavior we want.
class BackfillDeviseUserColumns < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE users
      SET encrypted_password = password_digest
      WHERE password_digest IS NOT NULL AND password_digest <> ''
    SQL
  end

  def down
    # No-op: encrypted_password is dropped only if the whole feature is rolled back.
  end
end
```

- [ ] **Step 2: Run the backfill**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails db:migrate`
Expected: `BackfillDeviseUserColumns: migrated`. Schema version → `2026_06_17_000002`.

- [ ] **Step 3: Add `devise` to the model (temporary co-existence with `has_secure_password`)**

> Devise's `database_authenticatable` defines `valid_password?`/`authenticate` against `encrypted_password`; `has_secure_password` defines `authenticate`/`password=` against `password_digest`. Having both is workable for ONE task only because Task 4 removes `has_secure_password`. To avoid a method clash in this interim, **add the full `devise` line but keep `has_secure_password` writing `password_digest`**, and make Devise read the same hashes (already backfilled). Edit `app/models/user.rb`: immediately AFTER the `has_secure_password validations: false` line (line 35), add:

```ruby
  # Devise — human-identity auth (web + device-login). Co-exists with has_secure_password
  # for exactly one migration step (Task 4 removes has_secure_password). The Devise modules
  # read encrypted_password (backfilled from password_digest); confirmable uses confirmed_at.
  devise :database_authenticatable, :registerable, :recoverable, :rememberable,
         :validatable, :confirmable, :lockable, :trackable, :timeoutable,
         :omniauthable, omniauth_providers: %i[openid_connect]
```

> NOTE: keeping both `has_secure_password` and `devise :database_authenticatable` will raise a `password=`/`authenticate` redefinition warning but not an error. This is intentional and transient — Task 4 deletes `has_secure_password` and the hand-rolled token methods. Do not "fix" the warning here.

- [ ] **Step 4: Replace web routes with `devise_for`**

Edit `config/routes.rb`. **Delete** the hand-rolled web-auth block (current lines 7–34: the `login`/`signup`/`confirm`/`confirmations`/`password`/`auth/:provider/callback` routes). **Replace** with:

```ruby
  # --- Human-identity web auth (Devise) ---
  # Governs the server-rendered web UI only. The v1 device-token machinery (namespace :v1
  # below) is unchanged. Custom controllers keep our redirect copy + OmniAuth seam.
  devise_for :users,
             controllers: {
               sessions:           "users/sessions",
               registrations:      "users/registrations",
               confirmations:      "users/confirmations",
               passwords:          "users/passwords",
               omniauth_callbacks: "users/omniauth_callbacks"
             }
```

Leave `root to: redirect("/files")`, the `trash`/`files`/`dev/blobs` routes, the whole `namespace :v1` block (edited later in Tasks 6–7), and the ActionCable mount intact.

- [ ] **Step 5: Add `web_device` to ApplicationController; make it a Devise controller base**

Replace `app/controllers/application_controller.rb` entirely with:

```ruby
class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :web_device

  # A stable, reusable Device for the signed-in web user. Lets the web UI mint per-user
  # presigned URLs and record commits through the SAME machinery as the desktop client —
  # the device-token bootstrap is unchanged; the web session just reuses it (CLAUDE.md §8).
  WEB_DEVICE_NAME = "web-session".freeze

  def web_device
    return unless user_signed_in?
    @web_device ||= current_user.devices.find_by(name: WEB_DEVICE_NAME) ||
                    Device.register!(user: current_user, name: WEB_DEVICE_NAME)
  end
end
```

> `current_user`, `user_signed_in?`, and `authenticate_user!` come from Devise. The old `require_login!`/`logged_in?` names are replaced — Step 6 updates the file controllers.

- [ ] **Step 6: Update file/trash controllers to Devise auth**

In every controller that previously did `include WebAuthentication` (at minimum `app/controllers/files_controller.rb` and `app/controllers/trash_controller.rb` — `grep -rl WebAuthentication app/controllers`), replace:

```ruby
  include WebAuthentication
  before_action :require_login!
```

with:

```ruby
  before_action :authenticate_user!
```

and replace any `logged_in?` calls with `user_signed_in?`. `current_user` and `web_device` are still available (Devise + ApplicationController). Do this for each such controller.

- [ ] **Step 7: Create the Devise controller subclasses**

Create `app/controllers/users/sessions_controller.rb`:

```ruby
# Devise session controller. Default behavior (authenticate email+password, reject
# unconfirmed via :confirmable, reject locked via :lockable). Subclassed so we can keep our
# routing namespace and add hooks later. No overrides needed today.
module Users
  class SessionsController < Devise::SessionsController
  end
end
```

Create `app/controllers/users/registrations_controller.rb`:

```ruby
# Devise registration (sign-up). :registerable + :confirmable means a new account is created
# unconfirmed and a confirmation email is sent; it cannot sign in until confirmed.
module Users
  class RegistrationsController < Devise::RegistrationsController
  end
end
```

Create `app/controllers/users/confirmations_controller.rb`:

```ruby
module Users
  class ConfirmationsController < Devise::ConfirmationsController
  end
end
```

Create `app/controllers/users/passwords_controller.rb`:

```ruby
module Users
  class PasswordsController < Devise::PasswordsController
  end
end
```

(`users/omniauth_callbacks_controller.rb` is created in Task 5; until then the route maps to a not-yet-existing class only when `OMNIAUTH_ENABLED` — Devise only adds the omniauth route because `:omniauthable` is on the model. To avoid a routing-to-missing-controller boot error, create the omniauth controller now as a stub and flesh it out in Task 5:)

Create `app/controllers/users/omniauth_callbacks_controller.rb`:

```ruby
# OmniAuth callbacks (filled in Task 5). Stub now so devise_for's omniauthable route resolves.
module Users
  class OmniauthCallbacksController < Devise::OmniauthCallbacksController
    def openid_connect = redirect_to(new_user_session_path, alert: "SSO not configured.")
    def failure        = redirect_to(new_user_session_path, alert: "SSO failed.")
  end
end
```

- [ ] **Step 8: Generate + lightly restyle Devise views**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails generate devise:views users`
Expected: creates `app/views/users/{sessions,registrations,confirmations,passwords,mailer,shared}/*`. (Namespaced views under `users/` match the `devise_for ... scope`.) These are server-rendered ERB matching the existing flows (signup→confirm→login→reset). No code logic needed; styling is cosmetic and out of scope for green tests.

- [ ] **Step 9: Delete the old web auth code + mailer + custom Session**

```bash
cd /tmp/tinkerex-devise-plan
git rm app/controllers/sessions_controller.rb \
       app/controllers/registrations_controller.rb \
       app/controllers/confirmations_controller.rb \
       app/controllers/passwords_controller.rb \
       app/controllers/omniauth_callbacks_controller.rb \
       app/controllers/concerns/web_authentication.rb \
       app/models/session.rb \
       app/mailers/user_mailer.rb
git rm -r app/views/user_mailer
```

> `Session` (custom server-side session model) is replaced by Devise/Warden cookie sessions. The `users.has_many :sessions` association and the `sessions` table are removed in Task 8 (after we confirm nothing else references them). For now, `User` still declares `has_many :sessions` — that's fine; the model file still exists until git-rm above removes `app/models/session.rb`. **Because `User` references `Session` only via the string-less `has_many :sessions, dependent: :destroy`, removing the model file would break that association on load.** Therefore, in `app/models/user.rb`, also delete the line `has_many :sessions, dependent: :destroy` in this step.

Edit `app/models/user.rb`: delete line 26 (`has_many :sessions, dependent: :destroy`).

- [ ] **Step 10: Replace the web auth integration test**

```bash
cd /tmp/tinkerex-devise-plan
git rm test/integration/web/auth_flow_test.rb
```

Create `test/integration/web/devise_auth_flow_test.rb`:

```ruby
require "test_helper"

# Human-identity web auth via Devise: sign-up -> confirmation email -> login (unconfirmed
# blocked) -> logout -> password reset. Uses Devise's standard paths
# (new_user_registration_path, user_session_path, etc.). The device-token + device-login
# enrollment is exercised separately (test/integration/v1/device_login_test.rb).
module Web
  class DeviseAuthFlowTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "correct horse battery staple".freeze

    setup { ActionMailer::Base.deliveries.clear }

    # --- sign up ----------------------------------------------------------------------
    test "sign up creates an unconfirmed account and sends a confirmation email" do
      assert_enqueued_emails 1 do
        assert_difference -> { User.count }, 1 do
          post user_registration_path, params: { user: {
            email: "alice@example.com", password: PASSWORD, password_confirmation: PASSWORD
          } }
        end
      end
      user = User.find_by(email: "alice@example.com")
      assert_not user.confirmed?, "new account starts unconfirmed"
      assert user.encrypted_password.present?, "password is hashed"
    end

    test "sign up rejects a mismatched password confirmation" do
      assert_no_difference -> { User.count } do
        post user_registration_path, params: { user: {
          email: "bob@example.com", password: PASSWORD, password_confirmation: "different"
        } }
      end
      assert_response :unprocessable_entity
    end

    test "sign up rejects a duplicate email" do
      User.create!(email: "dup@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_no_difference -> { User.count } do
        post user_registration_path, params: { user: {
          email: "dup@example.com", password: PASSWORD, password_confirmation: PASSWORD
        } }
      end
      assert_response :unprocessable_entity
    end

    # --- email confirmation -----------------------------------------------------------
    test "an UNCONFIRMED user cannot sign in" do
      User.create!(email: "unconf@example.com", password: PASSWORD)
      post user_session_path, params: { user: { email: "unconf@example.com", password: PASSWORD } }
      assert_response :unprocessable_entity
      # Not signed in -> the file UI redirects to login.
      get files_path
      assert_redirected_to new_user_session_path
    end

    test "confirming the email lets the user sign in" do
      raw = nil
      perform_enqueued_jobs do
        post user_registration_path, params: { user: {
          email: "carol@example.com", password: PASSWORD, password_confirmation: PASSWORD
        } }
      end
      mail = ActionMailer::Base.deliveries.last
      raw = mail.body.encoded[/confirmation_token=([^"'&\s]+)/, 1]
      assert raw.present?, "confirmation link carries a raw token"

      get user_confirmation_path(confirmation_token: raw)
      assert User.find_by(email: "carol@example.com").confirmed?

      post user_session_path, params: { user: { email: "carol@example.com", password: PASSWORD } }
      assert_redirected_to files_path
    end

    # --- login / logout ---------------------------------------------------------------
    test "login with the wrong password is rejected" do
      User.create!(email: "dave@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: "dave@example.com", password: "wrong" } }
      assert_response :unprocessable_entity
    end

    test "a confirmed user logs in, accesses the file UI, then logs out" do
      User.create!(email: "erin@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: "erin@example.com", password: PASSWORD } }
      assert_redirected_to files_path

      get files_path
      assert_response :success

      delete destroy_user_session_path
      get files_path
      assert_redirected_to new_user_session_path
    end

    # --- password reset ---------------------------------------------------------------
    test "requesting a reset emails a link for a known account" do
      User.create!(email: "gina@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_enqueued_emails 1 do
        post user_password_path, params: { user: { email: "gina@example.com" } }
      end
    end

    test "a valid reset token sets a new password and lets the user log in" do
      User.create!(email: "hank@example.com", password: PASSWORD, confirmed_at: Time.current)
      raw = nil
      perform_enqueued_jobs do
        post user_password_path, params: { user: { email: "hank@example.com" } }
      end
      mail = ActionMailer::Base.deliveries.last
      raw = mail.body.encoded[/reset_password_token=([^"'&\s]+)/, 1]
      assert raw.present?

      new_pw = "a brand new passphrase"
      put user_password_path, params: { user: {
        reset_password_token: raw, password: new_pw, password_confirmation: new_pw
      } }

      # Old password no longer works; new one does.
      post user_session_path, params: { user: { email: "hank@example.com", password: PASSWORD } }
      assert_response :unprocessable_entity
      post user_session_path, params: { user: { email: "hank@example.com", password: new_pw } }
      assert_redirected_to files_path
    end
  end
end
```

- [ ] **Step 11: Wire Devise mailer to deliver via Action Mailer queue + Active Job in test**

Devise mailers default to `deliver_later` only if configured; the test uses `assert_enqueued_emails`. Confirm `config/environments/test.rb` has `config.active_job.queue_adapter = :test` (Rails default in test). If absent, add it. Devise's `DeviseMailer` enqueues via `deliver_later` when `Devise.parent_mailer` config and Active Job are present; the tests above use `perform_enqueued_jobs`/`assert_enqueued_emails`, which handle both `deliver_later` and synchronous delivery via `ActionMailer::Base.deliveries`. No code change expected; verify in Step 13.

- [ ] **Step 12: Sweep references to removed names**

Run: `cd /tmp/tinkerex-devise-plan && grep -rn "WebAuthentication\|require_login!\|logged_in?\|UserMailer\|login_path\|signup_path\|confirm_email_path\|new_password_path\|edit_password_path\|::Session\b\|Session\.start!" app/ test/`
Expected: **no matches in `app/`** (all swapped). In `test/`, only the files we're rewriting in later tasks may still match — fix any stray `app/` reference now (e.g. a view partial linking to `login_path` → change to `new_user_session_path`, `signup_path` → `new_user_registration_path`).

Check views/layouts for nav links:
Run: `cd /tmp/tinkerex-devise-plan && grep -rn "login_path\|logout_path\|signup_path\|logged_in?\|current_user" app/views/`
Replace `login_path`→`new_user_session_path`, `logout_path`→`destroy_user_session_path` (method: :delete), `signup_path`→`new_user_registration_path`, `logged_in?`→`user_signed_in?` in any layout/partial.

- [ ] **Step 13: Run the new web auth test**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/integration/web/devise_auth_flow_test.rb`
Expected: PASS (all tests green). If "an UNCONFIRMED user cannot sign in" returns a redirect instead of 422, set `config.reflect_attributes`/use Devise's `:database_authenticatable` failure — Devise renders 422 on failed sign-in for HTML by default in 4.9 with Turbo; if your app returns a 401/redirect, adjust the assertion to `assert_response :unauthorized` OR add `config.navigational_formats = ["*/*", :html]`. Pick the response Devise actually returns and assert it (run once, read the status, lock the assertion).

- [ ] **Step 14: Run the full suite (lockstep swap complete)**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test`
Expected: PASS. The only expected change vs. baseline: the old `web/auth_flow_test.rb` is gone, the new `devise_auth_flow_test.rb` passes. `user_auth_test.rb` (still present) MUST still pass because `has_secure_password` is still on the model — its token-lifecycle methods still exist (Task 4 handles those). If `user_auth_test.rb` fails because `devise` redefined `password=`, comment-fix in Task 4; if it fails here, move its deletion forward (it is deleted in Task 4 Step 1 anyway — acceptable to delete now). **Decision rule:** if `user_auth_test.rb` is red after this swap, run `git rm test/models/user_auth_test.rb` now and recreate its OmniAuth portion in Task 5; note it in the commit.

- [ ] **Step 15: Commit**

```bash
cd /tmp/tinkerex-devise-plan
git add -A
git commit -m "feat(auth): swap web auth to Devise (controllers/routes/views) + tests

- devise_for :users with namespaced custom controllers
- backfill encrypted_password from password_digest (bcrypt, same format)
- ApplicationController.web_device preserved for the file UI presign path
- replace hand-rolled web auth integration test with Devise flows

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Model swap — remove has_secure_password + hand-rolled tokens; passwordless-OAuth support

**Files:**
- Modify: `app/models/user.rb`
- Delete: `test/models/user_auth_test.rb` (if not already removed in Task 3 Step 14)
- Test: `test/models/user_devise_model_test.rb`

- [ ] **Step 1: Write the failing test**

Create `test/models/user_devise_model_test.rb`:

```ruby
require "test_helper"

# The User model under Devise: password auth via encrypted_password, confirmable, and the
# CRITICAL passwordless path — OmniAuth-only accounts (no password) must stay VALID even
# though :validatable normally requires a password.
class UserDeviseModelTest < ActiveSupport::TestCase
  PASSWORD = "correct horse battery staple".freeze

  test "valid_password? authenticates against encrypted_password" do
    user = User.create!(email: "a@example.com", password: PASSWORD, confirmed_at: Time.current)
    assert user.valid_password?(PASSWORD)
    assert_not user.valid_password?("nope")
  end

  test "email is normalized (downcased + stripped)" do
    user = User.create!(email: "  MixedCase@Example.COM ", password: PASSWORD)
    assert_equal "mixedcase@example.com", user.email
  end

  test "a password account requires a password (validatable)" do
    user = User.new(email: "needspw@example.com")
    assert_not user.valid?, "no password + not omniauth -> invalid"
    assert_includes user.errors.attribute_names, :password
  end

  test "an OMNIAUTH-only account is valid with no password (password_required? = false)" do
    user = User.new(email: "oauth@example.com")
    user.identities.build(provider: "openid_connect", uid: "x-1")
    assert user.valid?, "omniauth identity present -> password not required"
    assert user.save
    assert user.encrypted_password.blank? || user.encrypted_password == "",
           "no usable password is set for an omniauth-only account"
  end

  test "next_seq! still works (sync hot path untouched)" do
    user = User.create!(email: "seq@example.com", password: PASSWORD)
    assert_equal 1, user.next_seq!
    assert_equal 2, user.next_seq!
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/models/user_devise_model_test.rb`
Expected: FAIL — the "OMNIAUTH-only account is valid" test fails (Devise `:validatable` requires a password; `password_required?` not yet overridden).

- [ ] **Step 3: Rewrite `app/models/user.rb`**

Replace the model with the Devise version. Keep ALL associations except `:sessions` (removed Task 3), keep `next_seq!` **verbatim**, keep `from_omniauth` + `AccountLinkRefused` **verbatim**, remove `has_secure_password` and all hand-rolled token methods (`generate_confirmation_token!`, `find_by_confirmation_token`, `confirm!` raw-digest version, `generate_reset_token!`, `find_by_reset_token`, `clear_reset_token!`, `generate_raw_token`, `digest_token`, `confirmed?`/`confirmed` scope — Devise provides `confirmed?`/`confirmed_at`). Add `password_required?` override.

```ruby
class User < ApplicationRecord
  has_many :devices, dependent: :destroy
  has_many :nodes, dependent: :destroy
  has_many :versions, dependent: :destroy
  has_many :chunks, dependent: :destroy
  has_many :changelog_entries, dependent: :destroy
  has_many :pending_commits, dependent: :destroy
  has_many :conflicts, dependent: :destroy
  has_many :file_locks, dependent: :destroy
  has_many :maker_items, class_name: "Maker::Item", dependent: :destroy
  has_many :maker_tags, class_name: "Maker::Tag", dependent: :destroy
  has_many :maker_taggings, class_name: "Maker::Tagging", dependent: :destroy
  has_many :maker_file_attachments, class_name: "Maker::FileAttachment", dependent: :destroy
  has_many :maker_collections, class_name: "Maker::Collection", dependent: :destroy
  has_many :maker_tasks, class_name: "Maker::Task", dependent: :destroy
  has_many :maker_projects, class_name: "Maker::Project", dependent: :destroy
  has_many :maker_build_log_entries, class_name: "Maker::BuildLogEntry", dependent: :destroy
  has_many :maker_locations, class_name: "Maker::Location", dependent: :destroy
  has_many :maker_suppliers, class_name: "Maker::Supplier", dependent: :destroy
  has_many :maker_inventory_items, class_name: "Maker::InventoryItem", dependent: :destroy
  has_many :maker_inventory_transactions, class_name: "Maker::InventoryTransaction", dependent: :destroy
  has_many :maker_previews, class_name: "Maker::Preview", dependent: :destroy
  has_many :maker_boms, class_name: "Maker::Bom", dependent: :destroy
  has_many :maker_bom_lines, class_name: "Maker::BomLine", dependent: :destroy
  has_many :identities, class_name: "UserIdentity", dependent: :destroy

  # Human-identity auth via Devise (CLAUDE.md §8; replaces the hand-rolled password +
  # confirmation/reset token flow). The v1 device-token + device-login enrollment is a
  # SEPARATE layer (Device model, Authentication concern) and is untouched.
  #   :confirmable  — email-ownership gate (unconfirmed accounts can't sign in / enroll).
  #   :lockable     — brute-force mitigation (also protects device-login).
  #   :trackable    — sign-in counters/timestamps.
  #   :timeoutable  — idle WEB sessions expire (device tokens are unaffected).
  #   :omniauthable — preserves the OAuth/OIDC seam (UserIdentity + from_omniauth).
  devise :database_authenticatable, :registerable, :recoverable, :rememberable,
         :validatable, :confirmable, :lockable, :trackable, :timeoutable,
         :omniauthable, omniauth_providers: %i[openid_connect]

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }

  # --- OmniAuth seam (docs/parity-roadmap.md §A) ------------------------------------
  # find-or-create a User from an OmniAuth auth hash.
  #
  # SECURITY — auto-linking by email is account-takeover-prone, so it is gated:
  #   * A returning identity (provider+uid we've seen) always maps to its user (safe).
  #   * We only auto-link an *email* to an existing account when (a) the IdP asserts the
  #     email is verified AND (b) that account has NO local password (so we never silently
  #     merge an OAuth login into a credentialed human account — a malicious/misconfigured
  #     IdP asserting a victim's address must not hijack their password login).
  #   * Otherwise we create a fresh account for this identity (unique email permitting).
  def self.from_omniauth(auth)
    provider = auth[:provider] || auth["provider"]
    uid      = auth[:uid]      || auth["uid"]
    info     = auth[:info]     || auth["info"] || {}
    email    = info[:email]    || info["email"]
    verified = omniauth_email_verified?(auth, info)

    identity = UserIdentity.find_by(provider:, uid:)
    return identity.user if identity

    existing = email.present? ? find_by(email:) : nil
    user =
      if existing && verified && !existing.password_set?
        # Safe to link: provider-verified email, and no local password to hijack.
        existing
      elsif existing
        # An account already owns this email and we won't silently take it over (an
        # unverified-email claim, or a credentialed human account). Refuse rather than
        # attach — the caller surfaces a generic SSO failure.
        raise AccountLinkRefused, "email already linked to an account"
      else
        # No collision: a brand-new account, so trusting the provider email is safe.
        new(email:)
      end

    # IdP delivered the email -> treat as confirmed (skip Devise's confirmation email).
    user.skip_confirmation! if user.respond_to?(:skip_confirmation!) && user.confirmed_at.nil?
    user.confirmed_at ||= Time.current if user.email.present?
    user.save!
    user.identities.find_or_create_by!(provider:, uid:)
    user
  end

  # Raised when an OAuth login would otherwise silently merge into a pre-existing account.
  class AccountLinkRefused < StandardError; end

  # True when the account has a usable bcrypt password (NOT an OmniAuth-only account).
  # Devise stores `""` (the column default) for passwordless accounts; bcrypt never
  # matches an empty digest, so a blank/"" encrypted_password means "no password".
  def password_set?
    encrypted_password.present?
  end

  # Devise :validatable requires a password by default. OmniAuth-only accounts have none,
  # so relax the requirement when an external identity is present (and no password is being
  # set). Mirrors the old `has_secure_password validations: false` intent.
  def password_required?
    return false if omniauth_identity?
    super
  end

  # An account backed by at least one external identity (built or persisted). Checks the
  # in-memory association too so `User.new` + `identities.build` validates without a save.
  def omniauth_identity?
    identities.any? { |i| i.persisted? || i.new_record? }
  end

  # Read the IdP's email-verification signal. Standard OIDC exposes `email_verified`;
  # different strategies surface it under `extra.raw_info` or `info`. Treat only an
  # explicit truthy claim as verified.
  def self.omniauth_email_verified?(auth, info)
    raw = (auth[:extra] || auth["extra"] || {})
    raw = (raw[:raw_info] || raw["raw_info"] || raw)
    claim = info[:email_verified] || info["email_verified"] ||
            raw[:email_verified] || raw["email_verified"]
    claim == true || claim.to_s == "true"
  end

  # Assign the next per-user changelog sequence. MUST be called inside a transaction, and
  # MUST be the FIRST write in it (before any node/version/changelog insert): locks the user
  # row so concurrent commits from multiple devices get distinct, ordered seqs. Portable —
  # `SELECT … FOR UPDATE` on Postgres; a harmless reload on SQLite (which serializes writes
  # globally anyway). Correct and fast on both.
  #
  # LOCK ORDERING (Postgres): the node/version/changelog/chunk rows written later in a commit
  # all FK-reference `users`, and a Postgres FK insert takes a `FOR KEY SHARE` lock on the
  # parent users row. If a commit inserted those FIRST and called next_seq! second, two
  # concurrent commits for the same user would each hold KEY SHARE and both want FOR UPDATE →
  # a lock-upgrade DEADLOCK (observed live under a concurrent-commit load test). Taking the
  # strong FOR UPDATE here, up front, makes a user's commits serialize cleanly with no
  # deadlock. All callers (Sync::Commit, Mutation, Restore, Conflicts) lock first.
  #
  # Pooler note: because the FOR UPDATE lock must span the read+write of head_seq, the
  # transaction's statements must run on ONE backend connection — i.e. a connection pooler in
  # front of Postgres MUST be in SESSION or TRANSACTION mode, never STATEMENT mode. See
  # docs/SYNC_SERVER.md "Connection pooler".
  def next_seq!
    lock!
    new_seq = head_seq + 1
    update_column(:head_seq, new_seq)
    new_seq
  end
end
```

> **Why `password_set?` replaces `password_digest.blank?`:** the old guard read `password_digest`; that column is dropped in Task 8. `encrypted_password` is the Devise equivalent, and `""` (its default) means "no password". The `from_omniauth` link guard now calls `!existing.password_set?` — semantically identical to the original `existing.password_digest.blank?`.

- [ ] **Step 4: Remove the obsolete `user_auth_test.rb` (if still present)**

```bash
cd /tmp/tinkerex-devise-plan
test -f test/models/user_auth_test.rb && git rm test/models/user_auth_test.rb || echo "already removed"
```

The OmniAuth-seam assertions from that file are re-added in Task 5; the token-lifecycle assertions are obsolete (Devise owns those flows, covered by the integration test in Task 3).

- [ ] **Step 5: Run the model test to verify it passes**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/models/user_devise_model_test.rb`
Expected: PASS (5 runs, 0 failures). In particular the passwordless-OAuth test passes because `password_required?` returns false when an identity is built.

- [ ] **Step 6: Run the full suite**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test`
Expected: PASS. The temporary `devise_gem_smoke_test.rb` still passes; the web flow test still passes; v1 sync + tenant-isolation tests unchanged. (The v1 `auth_test.rb` for pairing is still present and still green — pairing isn't removed until Task 6.)

- [ ] **Step 7: Commit**

```bash
cd /tmp/tinkerex-devise-plan
git add -A
git commit -m "refactor(auth): User devise model; passwordless-OAuth via password_required?

- replace has_secure_password + hand-rolled token methods with devise modules
- password_required? = false for omniauth-only accounts (passwordless stay valid)
- preserve from_omniauth AccountLinkRefused anti-takeover guard (password_set?)
- next_seq! unchanged (sync hot path)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 5: OmniAuth callbacks + OmniAuth-seam tests

**Files:**
- Modify: `app/controllers/users/omniauth_callbacks_controller.rb`
- Create: `config/initializers/omniauth.rb` (env-guarded provider wiring)
- Test: `test/models/user_omniauth_test.rb`, `test/integration/web/omniauth_callback_test.rb`

- [ ] **Step 1: Write the failing model test (re-homing the seam coverage)**

Create `test/models/user_omniauth_test.rb`:

```ruby
require "test_helper"

# The OmniAuth seam (User.from_omniauth) + its anti-takeover guard, preserved across the
# Devise migration.
class UserOmniauthTest < ActiveSupport::TestCase
  PASSWORD = "correct horse battery staple".freeze

  test "from_omniauth creates a confirmed user + identity for a new provider account" do
    auth = { provider: "openid_connect", uid: "abc-123", info: { email: "oauth@example.com" } }
    user = nil
    assert_difference [ -> { User.count }, -> { UserIdentity.count } ], 1 do
      user = User.from_omniauth(auth)
    end
    assert_equal "oauth@example.com", user.email
    assert user.confirmed?, "an IdP-verified email is treated as confirmed"
    assert_equal user, UserIdentity.find_by(provider: "openid_connect", uid: "abc-123").user
  end

  test "from_omniauth returns the same user for a repeat login" do
    auth = { provider: "openid_connect", uid: "uid-9", info: { email: "repeat@example.com" } }
    first = User.from_omniauth(auth)
    assert_no_difference [ -> { User.count }, -> { UserIdentity.count } ] do
      assert_equal first, User.from_omniauth(auth)
    end
  end

  test "from_omniauth REFUSES to take over an existing PASSWORD account by email" do
    User.create!(email: "link@example.com", password: PASSWORD, confirmed_at: Time.current)
    auth = { provider: "openid_connect", uid: "uid-link",
             info: { email: "link@example.com", email_verified: true } }
    assert_no_difference [ -> { User.count }, -> { UserIdentity.count } ] do
      assert_raises(User::AccountLinkRefused) { User.from_omniauth(auth) }
    end
  end

  test "from_omniauth REFUSES to take over an existing account when email is unverified" do
    User.create!(email: "unverified@example.com", confirmed_at: Time.current) # passwordless
    auth = { provider: "openid_connect", uid: "uid-unv", info: { email: "unverified@example.com" } }
    assert_raises(User::AccountLinkRefused) { User.from_omniauth(auth) }
  end

  test "from_omniauth links to an existing PASSWORDLESS account when email is verified" do
    existing = User.create!(email: "oauthonly@example.com", confirmed_at: Time.current)
    assert_not existing.password_set?
    auth = { provider: "openid_connect", uid: "uid-ok",
             info: { email: "oauthonly@example.com", email_verified: true } }
    assert_no_difference -> { User.count } do
      assert_equal existing, User.from_omniauth(auth)
    end
    assert existing.identities.exists?(provider: "openid_connect", uid: "uid-ok")
  end

  test "from_omniauth reads email_verified from extra.raw_info too" do
    User.create!(email: "rawinfo@example.com")
    auth = { provider: "openid_connect", uid: "uid-raw",
             info: { email: "rawinfo@example.com" },
             extra: { raw_info: { email_verified: true } } }
    assert_nothing_raised { User.from_omniauth(auth) }
  end
end
```

> Note: a passwordless `User.create!(email: ...)` now requires `password_required?` to be false. A bare `User.create!(email: ...)` has NO identity, so `password_required?` returns `super` (true) and would FAIL validation. **These tests create passwordless accounts that DON'T yet have an identity** (e.g. `oauthonly@example.com`). To keep them valid, the model must allow a passwordless account that was created WITHOUT going through password signup. Handle this by also treating a confirmed account with a pre-set `confirmed_at` and no password as omniauth-shaped is too loose. Instead, in these tests, build the identity OR pass `skip_password_validation`. The cleaner fix: in `from_omniauth`'s "no collision" branch we `new(email:)` then `save!` — at that point no identity is persisted yet, so `password_required?` must be false during that save. Step 3 adjusts the model.

- [ ] **Step 2: Run to verify it fails**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/models/user_omniauth_test.rb`
Expected: FAIL — the passwordless `User.create!(email: ...)` rows raise `Validation failed: Password can't be blank` (the bare create has no identity, so `password_required?` is true).

- [ ] **Step 3: Add an explicit "omniauth account" flag so passwordless saves are valid**

The `omniauth_identity?` check fails for a brand-new `new(email:)` before its identity exists. Add an in-memory flag set by `from_omniauth` and used by `password_required?`. Edit `app/models/user.rb`:

Add an attr_accessor near the top of the class body (after the `devise ...` block):

```ruby
  # Set transiently by from_omniauth so a passwordless OAuth account validates on first save
  # (before its UserIdentity row is persisted). Not a DB column.
  attr_accessor :omniauth_signup
```

Change `password_required?` to also honor the flag:

```ruby
  def password_required?
    return false if omniauth_signup || omniauth_identity?
    super
  end
```

In `from_omniauth`, set the flag on the user before `save!`. Change the body so that right before `user.save!` we add `user.omniauth_signup = true`:

```ruby
    user.skip_confirmation! if user.respond_to?(:skip_confirmation!) && user.confirmed_at.nil?
    user.confirmed_at ||= Time.current if user.email.present?
    user.omniauth_signup = true
    user.save!
    user.identities.find_or_create_by!(provider:, uid:)
    user
```

> The bare `User.create!(email: "oauthonly@example.com", confirmed_at: Time.current)` in the *test* still has no flag and no identity → would be invalid. So the tests that pre-create a passwordless account must set the flag. Update those test lines to `User.create!(email: "...", confirmed_at: Time.current, omniauth_signup: true)`. Edit `test/models/user_omniauth_test.rb`: in the "unverified" and "passwordless link" and "rawinfo" tests, add `omniauth_signup: true` to each pre-created passwordless `User.create!`. (The password-account creates already pass a password.)

- [ ] **Step 4: Flesh out the OmniAuth callbacks controller**

Replace `app/controllers/users/omniauth_callbacks_controller.rb`:

```ruby
# Devise OmniAuth callbacks. The callback authenticates the HUMAN web session only; the
# device-token + device-login enrollment underneath is untouched. from_omniauth carries the
# anti-takeover guard (AccountLinkRefused).
module Users
  class OmniauthCallbacksController < Devise::OmniauthCallbacksController
    def openid_connect
      auth = request.env["omniauth.auth"]
      return fail_sso("Single sign-on is not configured.") if auth.blank?

      user = User.from_omniauth(auth)
      sign_in(user, event: :authentication)
      redirect_to files_path, notice: "Signed in via #{auth.provider}."
    rescue User::AccountLinkRefused
      fail_sso("That email is already linked to an account. Sign in with your password.")
    rescue => e
      Rails.logger.warn("OmniAuth callback failed: #{e.class}: #{e.message}")
      fail_sso("Single sign-on failed.")
    end

    def failure
      fail_sso("Single sign-on was cancelled or failed.")
    end

    private

    def fail_sso(msg)
      redirect_to new_user_session_path, alert: msg
    end
  end
end
```

- [ ] **Step 5: Add the env-guarded OmniAuth provider initializer**

Create `config/initializers/omniauth.rb`:

```ruby
# OmniAuth/OIDC provider wiring — INERT unless OMNIAUTH_ENABLED is set (no hosted-IdP deps
# ship active; CLAUDE.md §9). Devise mounts the omniauthable routes from the model's
# omniauth_providers; this configures the strategy credentials when enabled.
if ENV["OMNIAUTH_ENABLED"].present?
  Devise.setup do |config|
    config.omniauth :openid_connect, {
      name: :openid_connect,
      scope: %i[openid email],
      response_type: :code,
      issuer: ENV["OIDC_ISSUER"],
      discovery: true,
      client_options: {
        identifier:   ENV["OIDC_CLIENT_ID"],
        secret:       ENV["OIDC_CLIENT_SECRET"],
        redirect_uri: ENV["OIDC_REDIRECT_URI"]
      }
    }
  end
end

# CSRF protection for the OmniAuth request phase (omniauth-rails_csrf_protection, MIT).
# Loaded unconditionally; harmless when no provider is configured.
require "omniauth/rails_csrf_protection" if defined?(OmniAuth)
```

- [ ] **Step 6: Write the callback integration test (mock mode)**

Create `test/integration/web/omniauth_callback_test.rb`:

```ruby
require "test_helper"

module Web
  # OmniAuth callback in mock mode (no live IdP). Verifies a new OAuth login creates an
  # account + session, and the anti-takeover guard surfaces as a generic SSO failure.
  class OmniauthCallbackTest < ActionDispatch::IntegrationTest
    setup do
      OmniAuth.config.test_mode = true
      OmniAuth.config.logger = Rails.logger
    end
    teardown do
      OmniAuth.config.test_mode = false
      OmniAuth.config.mock_auth[:openid_connect] = nil
    end

    def mock(email:, uid: "u-1", verified: true)
      OmniAuth.config.mock_auth[:openid_connect] = OmniAuth::AuthHash.new(
        provider: "openid_connect", uid: uid,
        info: { email: email, email_verified: verified }
      )
      Rails.application.env_config["omniauth.auth"] = OmniAuth.config.mock_auth[:openid_connect]
    end

    test "a new OAuth login creates an account and signs in" do
      mock(email: "newoauth@example.com")
      assert_difference -> { User.count }, 1 do
        get user_openid_connect_omniauth_callback_path
      end
      assert_redirected_to files_path
    end

    test "OAuth refusing to take over a password account fails generically" do
      User.create!(email: "victim@example.com", password: "correct horse battery staple",
                   confirmed_at: Time.current)
      mock(email: "victim@example.com", uid: "u-evil", verified: true)
      assert_no_difference -> { User.count } do
        get user_openid_connect_omniauth_callback_path
      end
      assert_redirected_to new_user_session_path
      assert_match(/already linked/i, flash[:alert])
    end
  end
end
```

> The route helper name `user_openid_connect_omniauth_callback_path` is what `devise_for :users, omniauthable` generates for the `openid_connect` provider. Verify with `bin/rails routes -g omniauth` in Step 8; if the helper differs, use the exact name printed.

- [ ] **Step 7: Run the OmniAuth tests**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/models/user_omniauth_test.rb test/integration/web/omniauth_callback_test.rb`
Expected: PASS.

- [ ] **Step 8: Verify the omniauth route helper name**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails routes -g omniauth`
Expected: a route like `user_openid_connect_omniauth_callback GET|POST /users/auth/openid_connect/callback users/omniauth_callbacks#openid_connect`. If the helper name differs, update the integration test's path helper accordingly and re-run Step 7.

- [ ] **Step 9: Full suite + commit**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test`
Expected: PASS.

```bash
cd /tmp/tinkerex-devise-plan
git add -A
git commit -m "feat(auth): Devise OmniAuth callbacks + OIDC seam (env-guarded) + tests

- preserve AccountLinkRefused anti-takeover guard on the callback path
- omniauth_signup flag keeps passwordless OAuth accounts valid on first save

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Remove the pairing-code flow (server)

**Files:**
- Modify: `config/routes.rb` (drop `auth/register`, `auth/pair`, `devices/pairing`)
- Modify: `app/controllers/v1/devices_controller.rb` (drop `pairing`)
- Delete: `app/controllers/v1/auth_controller.rb`, `app/models/device_pairing.rb`, `test/models/device_pairing_test.rb`, `test/integration/v1/auth_test.rb`
- Test: (device-login replaces these in Task 7; here we only remove)

> The v1 sync tests (tree/commit/changes/tenant-isolation) create users + devices directly (`User.create!`, `Device.register!`), not through `/v1/auth/register`. Removing the register/pair endpoints does not break them. Verify in Step 5.

- [ ] **Step 1: Remove the pairing/register routes**

Edit `config/routes.rb`. In the `namespace :v1` block, **delete** these lines:

```ruby
    post "auth/register", to: "auth#register"
    post "auth/pair", to: "auth#pair"
    resources :devices, only: [ :create ]
    post "devices/pairing", to: "devices#pairing"
```

and **replace** them with (the device-login endpoint; its action is added in Task 7, but routing it now is harmless since no test hits it until Task 7):

```ruby
    # Device enrollment by login (the Dropbox model): email+password -> a device token.
    # Replaces the pairing-code flow. No Bearer auth — the credentials ARE the auth.
    post "devices/login", to: "devices#login"
    # Direct add-a-device for an already-authenticated device (keeps its Bearer-authed path).
    resources :devices, only: [ :create ]
```

- [ ] **Step 2: Remove the pairing action from the devices controller**

Edit `app/controllers/v1/devices_controller.rb`. Delete the `pairing` action (and its comment block). The file becomes (the `login` action is added in Task 7):

```ruby
module V1
  class DevicesController < BaseController
    # POST /v1/devices { name } -> register an additional device for the current user.
    # (Direct path: the caller already holds a token and hands the new token off itself.)
    def create
      device = Device.register!(user: current_user, name: params[:name].presence || "device")
      render json: { device_id: device.id, device_token: device.plaintext_token }, status: :created
    end
  end
end
```

- [ ] **Step 3: Delete the v1 auth controller, the DevicePairing model, and their tests**

```bash
cd /tmp/tinkerex-devise-plan
git rm app/controllers/v1/auth_controller.rb \
       app/models/device_pairing.rb \
       test/models/device_pairing_test.rb \
       test/integration/v1/auth_test.rb
```

- [ ] **Step 4: Remove the `device_pairings` association from User**

> The `User` model no longer references `device_pairings` (we removed `has_many :device_pairings` is NOT in the Task-4 rewrite — confirm). Verify:

Run: `cd /tmp/tinkerex-devise-plan && grep -rn "device_pairing\|DevicePairing" app/ test/`
Expected: **no matches** (the Task-4 model rewrite already omitted `has_many :device_pairings`). If any match remains in `app/`, remove it.

- [ ] **Step 5: Run the v1 suite + full suite**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/integration/v1`
Expected: PASS — the sync endpoints (tree/commit/changes/nodes/conflicts/locks/tenant isolation) are unaffected; only `auth_test.rb` is gone.

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test`
Expected: PASS. (`device_pairings` table still exists in the schema — dropped in Task 8 — but nothing references it, so the suite is green.)

- [ ] **Step 6: Commit**

```bash
cd /tmp/tinkerex-devise-plan
git add -A
git commit -m "refactor(v1): remove pairing-code + register device bootstrap

- drop POST /v1/auth/register, /v1/auth/pair, /v1/devices/pairing
- delete V1::AuthController, DevicePairing model + tests
- route POST /v1/devices/login (action added next)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 7: Add device-login enrollment (server)

**Files:**
- Modify: `app/controllers/v1/devices_controller.rb` (add `login`)
- Test: `test/integration/v1/device_login_test.rb`

> **Security model:** device-login authenticates email+password via Devise's own primitives — `User.find_for_authentication(email:)` + `valid_password?(password)` — and honors `:confirmable` (`active_for_authentication?` is false for unconfirmed) and `:lockable` (`access_locked?` / `valid_for_authentication?` increments `failed_attempts` and locks after `maximum_attempts`). On success it mints a `Device` token. One generic 401 for unknown-email / bad-password / unconfirmed / locked — no enumeration beyond Devise defaults. The credentials cross the wire once (TLS); only the returned device token is stored client-side.

- [ ] **Step 1: Write the failing test**

Create `test/integration/v1/device_login_test.rb`:

```ruby
require "test_helper"

module V1
  # Device enrollment by login (the Dropbox model). Valid creds of a CONFIRMED account ->
  # a device token; wrong password / unknown email / unconfirmed / locked -> 401. Replaces
  # the pairing-code flow. The v1 sync endpoints keep using the returned device token.
  class DeviceLoginTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    setup { Storage::ChunkStore.reset! }

    def login(email:, password:, device_name: "laptop")
      post "/v1/devices/login",
           params: { email:, password:, device_name: }, as: :json
      response
    end

    test "valid credentials of a confirmed account return a device token" do
      User.create!(email: "dev@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_difference -> { Device.count }, 1 do
        r = login(email: "dev@example.com", password: PASSWORD)
        assert_response :created
        body = JSON.parse(r.body)
        assert body["device_token"].present?
        assert body["user_id"].present?
      end
    end

    test "the returned token works against the owner's library" do
      User.create!(email: "dev2@example.com", password: PASSWORD, confirmed_at: Time.current)
      token = JSON.parse(login(email: "dev2@example.com", password: PASSWORD).body)["device_token"]
      get "/v1/tree", params: { after_id: 0 }, headers: { "Authorization" => "Bearer #{token}" }
      assert_response :success
    end

    test "a wrong password is rejected with 401 and mints no device" do
      User.create!(email: "dev3@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_no_difference -> { Device.count } do
        r = login(email: "dev3@example.com", password: "wrong")
        assert_response :unauthorized
        assert_nil JSON.parse(r.body)["device_token"]
      end
    end

    test "an unknown email is rejected with the same generic 401 (no enumeration)" do
      r = login(email: "nobody@example.com", password: PASSWORD)
      assert_response :unauthorized
      assert_equal "invalid_credentials", JSON.parse(r.body)["error"]
    end

    test "an UNCONFIRMED account cannot enroll a device" do
      User.create!(email: "unconf@example.com", password: PASSWORD) # confirmed_at nil
      assert_no_difference -> { Device.count } do
        r = login(email: "unconf@example.com", password: PASSWORD)
        assert_response :unauthorized
        assert_equal "invalid_credentials", JSON.parse(r.body)["error"]
      end
    end

    test "the account LOCKS after too many failed attempts (lockable)" do
      User.create!(email: "lock@example.com", password: PASSWORD, confirmed_at: Time.current)
      # Devise maximum_attempts = 10 (config/initializers/devise.rb).
      11.times { login(email: "lock@example.com", password: "wrong") }
      assert User.find_by(email: "lock@example.com").access_locked?,
             "account is locked after exceeding maximum_attempts"
      # Even the CORRECT password is now refused while locked.
      assert_no_difference -> { Device.count } do
        r = login(email: "lock@example.com", password: PASSWORD)
        assert_response :unauthorized
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/integration/v1/device_login_test.rb`
Expected: FAIL — `No route matches`/`unknown action login` or 404 (the `login` action doesn't exist yet).

- [ ] **Step 3: Implement the `login` action**

Edit `app/controllers/v1/devices_controller.rb` — add the `login` action. Because `BaseController` includes `Authentication` (which `before_action :authenticate_device!`), the login endpoint must **skip** device-token auth (the caller has no token yet):

```ruby
module V1
  class DevicesController < BaseController
    # Device-login enrollment is the ONE v1 endpoint that authenticates by human
    # credentials, not a device token — so skip the Bearer gate here.
    skip_before_action :authenticate_device!, only: :login

    # POST /v1/devices/login { email, password, device_name } -> a device token.
    # Authenticates the human credentials via Devise (confirmable + lockable enforced),
    # then mints a Device. One generic 401 for unknown/bad/unconfirmed/locked (no
    # enumeration). The password crosses the wire once (TLS); the client stores only the
    # returned token.
    def login
      email    = params.require(:email)
      password = params.require(:password)
      user = User.find_for_authentication(email: email)

      # valid_for_authentication? runs the password check AND the lockable bookkeeping
      # (increments failed_attempts on a miss; locks at maximum_attempts). active_for_
      # authentication? enforces confirmable (and not-locked). Both must pass.
      authed =
        user&.valid_for_authentication? { user.valid_password?(password) } &&
        user.active_for_authentication?

      unless authed
        return render json: { error: "invalid_credentials" }, status: :unauthorized
      end

      device = Device.register!(user:, name: params[:device_name].presence || "device")
      render json: {
        user_id: user.id, device_id: device.id,
        device_token: device.plaintext_token, head_seq: user.head_seq
      }, status: :created
    end

    # POST /v1/devices { name } -> register an additional device for the current user.
    def create
      device = Device.register!(user: current_user, name: params[:name].presence || "device")
      render json: { device_id: device.id, device_token: device.plaintext_token }, status: :created
    end

    private

    # The v1 base rescues ParameterMissing as 400; for the login endpoint a missing field
    # should read as bad credentials (401), not a 400 — but a missing email/password is a
    # malformed request, so the inherited 400 is acceptable. (No override needed.)
  end
end
```

> **Important Devise detail:** `valid_for_authentication?` is the method that performs lockable accounting; calling `valid_password?` alone would NOT increment `failed_attempts`, so the lockable test would fail. The block form `user.valid_for_authentication? { user.valid_password?(password) }` is the documented way to run a custom credential check through the lockable machinery. `active_for_authentication?` returns false for unconfirmed (confirmable) and locked accounts.

- [ ] **Step 4: Run the device-login test**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/integration/v1/device_login_test.rb`
Expected: PASS (6 runs, 0 failures). If the "unknown email" case raises instead of returning 401 (because `find_for_authentication` returns nil and `nil&.valid_for_authentication?` short-circuits to nil → `authed` is falsey → 401), that's correct. If `ParameterMissing` surfaces as 400 in the wrong-password test, it won't — both params are present there.

- [ ] **Step 5: Full suite**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /tmp/tinkerex-devise-plan
git add -A
git commit -m "feat(v1): device-login enrollment (email+password -> device token)

- POST /v1/devices/login via Devise valid_for_authentication? (lockable) +
  active_for_authentication? (confirmable); generic 401; skips Bearer gate
- mints a Device on success; token is the only thing the client stores

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 8: Drop legacy user-auth columns + the device_pairings table

**Files:**
- Create: `db/migrate/20260617000003_drop_legacy_user_auth_columns.rb`
- Create: `db/migrate/20260617000004_drop_device_pairings.rb`
- Create: `db/migrate/20260617000005_drop_sessions.rb`
- Modify: `db/schema.rb` (via migrate)
- Test: `test/models/legacy_columns_dropped_test.rb`

> Run this only after Tasks 3–7 prove nothing reads `password_digest`, the raw-digest token columns, the `device_pairings` table, or the custom `sessions` table.

- [ ] **Step 1: Write the failing test**

Create `test/models/legacy_columns_dropped_test.rb`:

```ruby
require "test_helper"

class LegacyColumnsDroppedTest < ActiveSupport::TestCase
  test "legacy hand-rolled auth columns are gone" do
    cols = User.column_names
    %w[password_digest confirmation_token_digest reset_token_digest reset_sent_at].each do |c|
      assert_not_includes cols, c, "#{c} should be dropped (Devise replaces it)"
    end
  end

  test "device_pairings table is dropped" do
    assert_not ActiveRecord::Base.connection.table_exists?(:device_pairings)
  end

  test "the custom sessions table is dropped (Devise/Warden cookie sessions now)" do
    assert_not ActiveRecord::Base.connection.table_exists?(:sessions)
  end

  test "Devise columns remain" do
    assert_includes User.column_names, "encrypted_password"
    assert_includes User.column_names, "confirmed_at"
    assert_includes User.column_names, "confirmation_sent_at"
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/models/legacy_columns_dropped_test.rb`
Expected: FAIL — `password_digest should be dropped` (columns/tables still present).

- [ ] **Step 3: Write the drop migrations**

Create `db/migrate/20260617000003_drop_legacy_user_auth_columns.rb`:

```ruby
# Drop the hand-rolled auth columns now that Devise owns confirmation/reset/password.
# encrypted_password (Devise) was backfilled from password_digest in 000002. confirmed_at
# and confirmation_sent_at are RETAINED (Devise :confirmable uses them).
class DropLegacyUserAuthColumns < ActiveRecord::Migration[8.1]
  def up
    remove_index :users, :confirmation_token_digest, if_exists: true
    remove_index :users, :reset_token_digest, if_exists: true
    remove_column :users, :password_digest, :string
    remove_column :users, :confirmation_token_digest, :string
    remove_column :users, :reset_token_digest, :string
    remove_column :users, :reset_sent_at, :datetime
  end

  def down
    add_column :users, :password_digest, :string
    add_column :users, :confirmation_token_digest, :string
    add_column :users, :reset_token_digest, :string
    add_column :users, :reset_sent_at, :datetime
    add_index :users, :confirmation_token_digest, unique: true
    add_index :users, :reset_token_digest, unique: true
  end
end
```

Create `db/migrate/20260617000004_drop_device_pairings.rb`:

```ruby
# Remove the pairing-code mechanism (replaced by device-login enrollment).
class DropDevicePairings < ActiveRecord::Migration[8.1]
  def up
    drop_table :device_pairings, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

Create `db/migrate/20260617000005_drop_sessions.rb`:

```ruby
# The custom server-side Session model is replaced by Devise/Warden cookie sessions.
class DropSessions < ActiveRecord::Migration[8.1]
  def up
    drop_table :sessions, if_exists: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
```

> **Before running:** confirm the exact column type/name of `device_pairings` and `sessions` for an accurate `schema.rb` regeneration. The `if_exists: true` guards make these idempotent. If the `sessions` table has a foreign key to `users` (it does — `add_foreign_key "sessions", "users"` in schema.rb), `drop_table` removes it with the table.

- [ ] **Step 4: Migrate**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails db:migrate`
Expected: three migrations applied; schema version → `2026_06_17_000005`. `db/schema.rb` no longer has `password_digest`/`confirmation_token_digest`/`reset_token_digest`/`reset_sent_at` on `users`, and no `device_pairings`/`sessions` tables.

- [ ] **Step 5: Run the test + full suite**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test test/models/legacy_columns_dropped_test.rb`
Expected: PASS (4 runs, 0 failures).

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test`
Expected: PASS.

- [ ] **Step 6: Remove the temporary gem-smoke test (superseded)**

```bash
cd /tmp/tinkerex-devise-plan && git rm test/models/devise_gem_smoke_test.rb
```

(Its assertions are now implied by the rest of the suite running at all.)

- [ ] **Step 7: Commit**

```bash
cd /tmp/tinkerex-devise-plan
git add -A
git commit -m "chore(db): drop legacy auth columns, device_pairings + sessions tables

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 9: Update the Rust sync-client (device-login) — specification

> The Rails suite does not depend on the Rust client; these are the client-side changes the migration requires. They are listed as concrete tasks. Run `cargo build` / `cargo test` in `client/sync-client` and `client/sync-engine` to verify (the engine tests need a running server — boot `STORAGE_BACKEND=memory bin/rails server -p 3001` first, per CLAUDE.md §13).

**Files:**
- Modify: `client/sync-client/src/lib.rs`
- Modify: `client/sync-engine/{tests,examples}/*` and `client/maker-app/src-tauri/src/lib.rs` (callers)

- [ ] **Step 1: Replace `register`/`pair`/`create_pairing` with `device_login`**

In `client/sync-client/src/lib.rs`, delete `register`, `pair`, and `create_pairing` (lines ~362–402) and the now-unused `PairingResponse` struct (lines ~124–128). Add:

```rust
    /// Enroll this device by logging in (the Dropbox model): POST /v1/devices/login with the
    /// user's email + password. The server authenticates via Devise (confirmed + unlocked
    /// account required) and returns a device token, which we store on the client. The
    /// password is sent ONCE over TLS and never persisted — only the token is kept.
    pub fn device_login(
        &mut self,
        email: &str,
        password: &str,
        device_name: &str,
    ) -> Result<RegisterResponse> {
        let resp = self
            .http
            .post(self.url("/v1/devices/login"))
            .json(&serde_json::json!({
                "email": email, "password": password, "device_name": device_name
            }))
            .send()?;
        let reg: RegisterResponse = Self::json(resp)?;
        self.token = Some(reg.device_token.clone());
        Ok(reg)
    }
```

`RegisterResponse` (`user_id`, `device_id`, `device_token`, `head_seq`) is unchanged — the device-login JSON matches it. `create_device` (Bearer-authed add-a-device) is unchanged.

- [ ] **Step 2: Update all callers**

Replace every `.register(email, name)` with `.device_login(email, password, name)`, supplying a password. In test/example helpers that previously did `register(&format!("x-{}@example.com", uniq()), "device-A")`, the account must now pre-exist and be confirmed — add a helper that creates a confirmed user with a known password via a test seam, OR (simpler for the Rust integration tests) hit a test-only signup. Because the Rust tests run against a real Rails server, the cleanest approach is a small test helper in the Rails app:

- Add a test-only endpoint or rake task is undesirable (it would ship). Instead, the Rust integration tests should create the user through Devise's normal API is not exposed as JSON. **Specify:** add a guarded, non-production endpoint `POST /v1/test/users { email, password }` mounted only when `ENV["ENABLE_TEST_SIGNUP"]` is set (the CI server boot for Rust tests sets it), which creates a confirmed user. This mirrors the existing `STORAGE_BACKEND=memory` test-server pattern. Then Rust helpers do: `create_test_user(email, pw)` → `client.device_login(email, pw, name)`.

  - Rails side (Task 9b, server): `config/routes.rb` inside `unless Rails.env.production?` add `post "v1/test/users", to: "v1/test_users#create"` guarded additionally by `ENV["ENABLE_TEST_SIGNUP"]`; controller `app/controllers/v1/test_users_controller.rb` creates `User.create!(email:, password:, confirmed_at: Time.current)`. (Spell this out as its own server task if executing; included here as the enabling change for the Rust tests.)

- For the two-device tests (`two_device_e2e.rs`, `integration.rs` pairing cases): replace the `create_pairing`/`pair` choreography with two `device_login` calls for the SAME confirmed account (each device logs in independently — the multi-device-from-one-account model). Update `pair_two_devices.rs`/`pair_three_devices.rs` examples likewise (rename or repurpose to "login N devices").

- `client/maker-app/src-tauri/src/lib.rs`: replace `sync_register`/`sync_pair`/`create_pairing` Tauri commands with a single `sync_login(server_url, email, password, mountpoint)` calling `client.device_login(...)`; drop the pairing UI calls. (The app UI change is out of scope for this plan beyond the command surface.)

- [ ] **Step 3: Build + verify**

Run: `cd /tmp/tinkerex-devise-plan/client/sync-client && cargo build`
Expected: compiles (no references to removed `register`/`pair`/`create_pairing`/`PairingResponse`).

Run (with a test server up + `ENABLE_TEST_SIGNUP=1`): `cd /tmp/tinkerex-devise-plan/client/sync-engine && SYNC_IT_SERVER_URL=http://localhost:3001 cargo test --test integration`
Expected: PASS (the device-login path replaces register/pair).

- [ ] **Step 4: Commit**

```bash
cd /tmp/tinkerex-devise-plan
git add -A
git commit -m "feat(client): device_login replaces register/pair/create_pairing

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 10: Full-suite green gate

**Files:** none (verification only)

- [ ] **Step 1: Run the entire Rails suite**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test`
Expected: PASS — 0 failures, 0 errors. The suite includes: Devise web auth flow, Devise model + passwordless OAuth, OmniAuth seam + callback, device-login enrollment, the unchanged v1 sync + tenant-isolation tests (still authenticate with device tokens), and the legacy-columns-dropped check.

- [ ] **Step 2: Run the system/integration sweeps if present**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails test:all 2>/dev/null || bin/rails test`
Expected: PASS.

- [ ] **Step 3: Brakeman + a route audit (no leftover hand-rolled auth paths)**

Run: `cd /tmp/tinkerex-devise-plan && bin/rails routes | grep -E "devise|users|devices/login"`
Expected: Devise routes present (`new_user_session`, `user_registration`, `user_confirmation`, `user_password`, `user_openid_connect_omniauth_callback`) and `POST /v1/devices/login`. No `login`/`signup`/`auth/register`/`auth/pair`/`devices/pairing` routes remain.

Run: `cd /tmp/tinkerex-devise-plan && bundle exec brakeman -q --no-pager 2>/dev/null | tail -20`
Expected: no NEW high-confidence warnings introduced by the auth change (Devise is a known-good pattern).

- [ ] **Step 4: Final commit (if any doc/route tweaks)**

```bash
cd /tmp/tinkerex-devise-plan
git add -A
git commit -m "test(auth): full-suite green after Devise + device-login migration

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>" --allow-empty
```

---

## Self-Review

**1. Spec coverage** (target design items 1–7 from the brief):

| Spec item | Task(s) |
|---|---|
| 1. Devise gem + modules (`database_authenticatable, registerable, recoverable, rememberable, validatable, confirmable, lockable, trackable, timeoutable, omniauthable`) | Task 1 (gem), Task 2 (columns + initializer config: lockable/timeoutable/confirmable options), Task 4 (`devise` module list) |
| 2. KEEP device-token machinery unchanged (`Device`, `Authentication` concern, ActionCable `?token=`, all `/v1/*`) | Untouched throughout; Task 7 `skip_before_action :authenticate_device!` only on the new `login` action; verified green in Tasks 6–7, 10 |
| 3. Device enrollment → device-login `POST /v1/devices/login`; REMOVE pairing (`DevicePairing` model+table, `/v1/devices/pairing`, `/v1/auth/pair`, `/v1/auth/register`); update sync-client | Task 6 (remove), Task 7 (add login + lockable/confirmable enforcement + generic 401), Task 8 (drop table), Task 9 (client) |
| 4. Web human auth via Devise; data-preserving column migration (`password_digest`→`encrypted_password`, keep `confirmed_at`, map confirmation/reset, add lockable/trackable/rememberable) | Task 2 (add cols), Task 3 (backfill + routes/controllers/views), Task 8 (drop legacy) |
| 5. Passwordless OAuth under Devise (`password_required?` false for omniauth) + preserve `from_omniauth` + `AccountLinkRefused` | Task 4 (`password_required?`, `omniauth_signup`, `password_set?`, preserved guard), Task 5 (callbacks + tests) |
| 6. Permissive licensing confirmed | Header "Licensing note" + Task 1 comment |
| 7. Tests: adapt web auth, ADD device-login (valid→token, wrong pw→401, unconfirmed→reject, locked after N), v1 sync/tenant unchanged, remove pairing tests, final full `bin/rails test` | Task 3 (web), Task 5 (omniauth), Task 6 (remove pairing tests), Task 7 (device-login incl. lockable), Task 10 (full green) |

No gaps.

**2. Placeholder scan:** No "TBD"/"implement later"/"add appropriate X". Every code step shows complete code; every migration is complete; commands have expected output. The two places that say "verify the exact name/status and lock the assertion" (Task 3 Step 13 sign-in failure status; Task 5 Step 8 omniauth route helper) are explicit verification-then-fix instructions, not deferred work — Devise's response code (422 vs 401) and generated helper name are environment-determined and must be read from the actual install, which is the correct TDD action, not a placeholder.

**3. Type / name consistency:**
- `RegisterResponse` (Rust) reused by `device_login` — unchanged shape (`user_id, device_id, device_token, head_seq`), and the Rails `login` action renders exactly those keys (Task 7 Step 3). Consistent.
- `password_set?` defined in Task 4 and used by `from_omniauth` (Task 4) and the omniauth test (Task 5). Consistent.
- `omniauth_signup` accessor defined in Task 5 Step 3 and used in `from_omniauth` (set before `save!`) and `password_required?`. Consistent.
- `web_device` moved from `WebAuthentication` to `ApplicationController` (Task 3 Step 5); callers in file controllers keep calling `web_device` (Task 3 Step 6). Consistent.
- Devise route helpers (`new_user_session_path`, `user_registration_path`, `user_confirmation_path`, `user_password_path`, `destroy_user_session_path`) used consistently across Task 3 test + Task 5 test + view sweep (Task 3 Step 12).
- Migration numbers strictly increasing and all `> 20260616130001`: `000001` (add cols), `000002` (backfill), `000003` (drop legacy cols), `000004` (drop pairings), `000005` (drop sessions). Schema version ends at `2026_06_17_000005`. Consistent.
- `valid_for_authentication?` (lockable accounting) used in Task 7 and asserted by the lockable test (Task 7 Step 1). Consistent.

One naming caution surfaced and resolved: the brief mentions `find_for_authentication` + `valid_password?`; the plan uses `find_for_authentication` to locate the user and `valid_for_authentication? { valid_password? }` to run the check **through** lockable (plain `valid_password?` would not increment `failed_attempts`, breaking the "locks after N" requirement). This is the correct Devise idiom and is called out in Task 7's note.

Plan is internally consistent and fully covers the spec.
