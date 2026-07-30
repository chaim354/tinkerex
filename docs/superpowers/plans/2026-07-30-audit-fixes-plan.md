# Audit Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every finding in `docs/AUDIT-2026-07-30.md` that is fixable in code — six config
hardening items, one N+1, one uniqueness index, account-deletion re-authentication — and build
the three test layers whose absence let the N+1 ship (query-count guards, the 13 unexercised web
actions, a cross-user authorization sweep).

**Architecture:** No new subsystems. Nine of the eleven code changes are one to five lines in
`config/` or a Devise controller subclass; the value is concentrated in the tests that pin them.
Order is dictated by two real dependencies: the rate limiter needs a working cache store, and
`config.paranoid` changes user-visible copy in flows whose tests must move with it. Two findings
(S5 upload quota, P3 pagination) are deliberately **not** in this plan — they need a product
number, not an implementation, and are tracked in `docs/OPEN-WORK.md` §1 as Decisions.

**Tech Stack:** Rails 8.1.3, Devise, Minitest + `ActionDispatch::IntegrationTest`, SQLite (test),
`ActiveSupport::Notifications` for query counting, `bin/ci` for the gates.

---

## Baseline and non-negotiables

**Before touching anything, record the baseline by running it.** `docs/STATUS.md`'s per-entry
suite counts do not form a chain and cannot be used as a baseline — this is documented in that
file. Measure:

```bash
bin/rails db:test:prepare test 2>&1 | tail -3
```

Expected at merge-base `5051404`: **1690 runs / 5918 assertions / 0 failures / 0 errors / 11 skips**.

**Three legs, not one.** Every task's final verification runs all three FileLayer backends. The
share and s3 legs catch tests that silently depend on the ambient `LIBRARY_BACKEND`. Copy these
invocations verbatim — `LIBRARY_BACKEND=share bin/rails test` **without** `LIBRARY_PATH` reports
`1 failure / 202 errors` because `LibraryBackendCheck` refuses to boot, and it looks exactly like
a broken share backend:

```bash
bin/rails db:test:prepare test
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test
LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=stub LIBRARY_S3_REGION=us-east-1 \
  LIBRARY_S3_ACCESS_KEY_ID=stub LIBRARY_S3_SECRET_ACCESS_KEY=stub \
  LIBRARY_S3_ENDPOINT=http://stub.invalid bin/rails test
```

If the s3 knobs above have drifted, read them out of `.github/workflows/ci.yml`'s
`test-s3-backend` job rather than guessing.

**Mutation-check every guard.** For each new test, break the thing it guards, watch it go red,
then restore. A test that passes with and without the code it exists to pin is worse than no
test — this repo has shipped that exact failure twice (nine gating tests that could not fail for
their stated reason; a fake that shared the code's misunderstanding). Each task below names its
mutation explicitly.

**rubocop must stay clean on touched files:**

```bash
bin/rubocop
```

---

## File structure

**Created:**

| Path | Responsibility |
|---|---|
| `test/integration/web/page_query_budget_test.rb` | One place asserting every main web page's query count is constant in N. The guard layer T3. |
| `test/integration/web/account_settings_test.rb` | `registrations#edit`/`#update`/`#destroy`/`#cancel` + the account-deletion re-auth rule. Covers T1's highest-value half and pins S10. |
| `test/integration/web/auth_throttle_test.rb` | Rate limiting on the four auth entry points (S3). |
| `test/integration/web/account_enumeration_test.rb` | Paranoid-mode behaviour: an unknown email is indistinguishable from a known one (S2). |
| `test/integration/web/auth_pages_test.rb` | The remaining unexercised auth GETs: `passwords#new`/`#edit`, `confirmations#new`, `registrations#new`, `omniauth_callbacks#passthru` (T1). |
| `test/integration/web/cross_user_authorization_test.rb` | The systematic sweep: every mutating web action, driven as a second user (T2). |
| `test/integration/web/entry_photos_test.rb` | `projects/entry_photos#create`/`#destroy` (T1 — `#destroy` is currently unexercised). |
| `db/migrate/<ts>_add_unique_index_to_maker_file_attachments.rb` | Dedupe then constrain (S6). |
| `test/models/maker/file_attachment_uniqueness_test.rb` | Pins the constraint and the dedupe (S6). |

**Modified:**

| Path | Change |
|---|---|
| `config/environments/production.rb:27-31,85-86` | Env-gated `assume_ssl`/`force_ssl` (S1); `cache_store` (S9). |
| `config/environments/test.rb:23` | `config.action_controller.cache_store = :memory_store` so throttles can fire in tests (S3 prerequisite). |
| `config/initializers/devise.rb:93,183` | `paranoid` (S2); `password_length` floor (S7). |
| `config/initializers/content_security_policy.rb` | Report-only CSP (S4). |
| `app/controllers/users/sessions_controller.rb` | `rate_limit` on `create` (S3). |
| `app/controllers/users/passwords_controller.rb` | `rate_limit` on `create` (S3). |
| `app/controllers/users/confirmations_controller.rb` | `rate_limit` on `create` (S3). |
| `app/controllers/users/registrations_controller.rb` | `rate_limit` on `create` (S3); require password on `destroy` (S10). |
| `app/controllers/projects_controller.rb:40` | Add `:rich_text_body` to the eager load (P1). |
| `app/views/devise/registrations/edit.html.erb` | Password field on the delete form (S10) — create if Devise's view is not yet generated. |
| `CLAUDE.md` §4 | Correct the "Solid Queue/Cache/Cable" claim (drift noted in audit S9). |
| `docs/STATUS.md` | Record the arc. |

---

## Task 1: Query-count guards — build the net before fixing what it catches

This comes first on purpose. P1's fix is one line; the reason P1 shipped is that nothing measured
query counts. Writing the guard first means the fix is verified by a failing-then-passing test
rather than by a number in a document.

**Files:**
- Create: `test/integration/web/page_query_budget_test.rb`

- [ ] **Step 1: Write the failing test**

The assertion shape is **constant in N**, not a literal count. The argument is the one already
made in `test/services/file_layer/adapter_contract.rb:47-55`: a literal encodes one
configuration's query shape into a test that other configurations also run. Here the counts
differ per FileLayer backend, so a literal would fail on two of the three legs.

Create `test/integration/web/page_query_budget_test.rb`:

```ruby
require "test_helper"

module Web
  # Every page here is rendered at two data sizes and must issue the SAME number of queries.
  #
  # WHY CONSTANCY AND NOT A LITERAL: the counts differ per FileLayer backend (chunk resolves
  # file metadata differently from share/s3), so a literal would pin one leg and fail the other
  # two. Constancy is also the property that actually matters — a page that costs 12 queries is
  # fine forever; a page that costs one query per row is a page that dies on real data.
  #
  # THIS FILE EXISTS BECAUSE projects#show REGRESSED TO LINEAR AND NOTHING NOTICED. Rich text
  # bodies arrived with the project-page overhaul and the eager load was never extended, so the
  # page went from flat to +1 query per build-log entry with the whole suite still green.
  class PageQueryBudgetTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    SMALL = 3
    LARGE = 15

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      @user = User.create!(email: "budget@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    # SCHEMA/TRANSACTION and PRAGMA are excluded: they are this page's cost only by accident of
    # being first in the process. The warm-up request below is what really keeps them out.
    def count_queries
      n = 0
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
        unless payload[:name].in?([ "SCHEMA", "TRANSACTION" ]) || payload[:sql].start_with?("PRAGMA")
          n += 1
        end
      end
      yield
      n
    ensure
      ActiveSupport::Notifications.unsubscribe(sub)
    end

    # Render once to warm every lazy load (schema, routes, view compilation), then measure twice.
    def assert_constant_queries(path, seed_small, seed_large, label)
      seed_small.call
      get path
      assert_response :success, "#{label} must render before it can be budgeted"
      small = count_queries { get path }

      seed_large.call
      get path
      large = count_queries { get path }

      assert_equal small, large,
                   "#{label} issued #{small} queries at the small size and #{large} at the " \
                   "large one — it grows with the data. Add the missing eager load."
    end

    def node!(id, name)
      @user.nodes.create!(node_id: id, name: name, kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)
    end

    test "projects#show does not grow with attachments, tasks or build-log entries" do
      project = @user.maker_projects.create!(name: "Budgeted", status: "active")
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          node!(id, "#{id}.stl")
          project.file_attachments.create!(user: @user, node_id: id, role: "model")
          project.tasks.create!(user: @user, title: "task #{id}")
          project.build_log_entries.create!(user: @user, body: "entry #{id}",
                                            logged_at: Time.current)
        end
      end

      assert_constant_queries(project_path(project),
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "projects#show")
    end

    test "projects#index does not grow with the number of projects" do
      add = ->(prefix, count) do
        count.times { |i| @user.maker_projects.create!(name: "#{prefix}#{i}", status: "active") }
      end
      assert_constant_queries(projects_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "projects#index")
    end

    test "models#index does not grow with the number of models" do
      add = ->(prefix, count) do
        count.times { |i| @user.maker_models.create!(title: "#{prefix}#{i}", slug: "#{prefix}#{i}") }
      end
      assert_constant_queries(models_path,
                              -> { add.call("s", SMALL) },
                              -> { add.call("l", LARGE - SMALL) },
                              "models#index")
    end

    test "models#show does not grow with attachments or print runs" do
      model = @user.maker_models.create!(title: "Shown", slug: "shown")
      add = lambda do |prefix, count|
        count.times do |i|
          id = "#{prefix}#{i}"
          node!(id, "#{id}.stl")
          model.file_attachments.create!(user: @user, node_id: id, role: "model")
          model.print_runs.create!(user: @user, printed_on: Date.current, outcome: "success")
        end
      end
      assert_constant_queries(model_path(model),
                              -> { add.call("ms", SMALL) },
                              -> { add.call("ml", LARGE - SMALL) },
                              "models#show")
    end

    test "files#index folder view does not grow with the number of nodes" do
      add = ->(prefix, count) { count.times { |i| node!("#{prefix}#{i}", "#{prefix}#{i}.stl") } }
      assert_constant_queries(files_path,
                              -> { add.call("fs", SMALL) },
                              -> { add.call("fl", LARGE - SMALL) },
                              "files#index (folder)")
    end

    test "trash#index does not grow with the number of tombstones" do
      add = lambda do |prefix, count|
        count.times do |i|
          @user.nodes.create!(node_id: "#{prefix}#{i}", name: "#{prefix}#{i}.stl", kind: "file",
                              size: 1, mtime: 1_700_000_000_000_000_000, deleted: true)
        end
      end
      assert_constant_queries(trash_index_path,
                              -> { add.call("ts", SMALL) },
                              -> { add.call("tl", LARGE - SMALL) },
                              "trash#index")
    end
  end
end
```

- [ ] **Step 2: Run it and confirm exactly one test fails, for the right reason**

```bash
bin/rails test test/integration/web/page_query_budget_test.rb
```

Expected: **1 failure of 6**, and the message must name the growth:

```
projects#show issued 14 queries at the small size and 26 at the large one — it grows with
the data. Add the missing eager load.
```

If any of the other five also fail, stop and investigate — the audit measured them flat
(`projects#index` 4, `models#index` 5, `models#show` 11, `files#index` 5, `trash#index` 3), so a
failure there is a new finding, not a bad test.

- [ ] **Step 3: Commit the guard while it is still red for `projects#show`**

Committing the failing guard separately makes the regression visible in history rather than
folding it into its own fix.

```bash
git add test/integration/web/page_query_budget_test.rb
git commit -m "test(web): budget every main page's query count, constant in N

projects#show FAILS this: 14 queries at 3 build-log entries, 26 at 15. The other five
pages are flat. Nothing in the suite measured query counts, which is how a page regressed
from flat to linear with every test still green."
```

---

## Task 2: Fix the `projects#show` N+1 (P1)

**Files:**
- Modify: `app/controllers/projects_controller.rb:40`

- [ ] **Step 1: Apply the fix**

`Maker::BuildLogEntry` declares `has_rich_text :body` (`app/models/maker/build_log_entry.rb:8`),
and Action Text names that association `rich_text_body` — that is the name to eager-load, not
`:body`.

In `app/controllers/projects_controller.rb`, line 40, change:

```ruby
    @entries = @project.build_log_entries.includes(:file_attachments).reorder(logged_at: :desc).to_a
```

to:

```ruby
    # :rich_text_body is Action Text's association for `has_rich_text :body`. Without it, each
    # entry's body is its own query — 15 entries cost 15 extra round-trips. Pinned by
    # test/integration/web/page_query_budget_test.rb.
    @entries = @project.build_log_entries
                       .includes(:file_attachments, :rich_text_body)
                       .reorder(logged_at: :desc).to_a
```

- [ ] **Step 2: Run the guard and confirm it goes green**

```bash
bin/rails test test/integration/web/page_query_budget_test.rb
```

Expected: **6 runs, 0 failures.** The page is now flat at **12 queries** at both sizes — fewer
than the 14 it cost at the small size before, because three per-entry queries collapse into one
batched load.

- [ ] **Step 3: Confirm the project page still renders correctly**

The eager load must not change what is displayed.

```bash
bin/rails test test/integration/web/project_build_log_test.rb test/integration/web/projects_flow_test.rb
```

Expected: 0 failures.

- [ ] **Step 4: Mutation-check**

Revert the one-line change, confirm the guard goes red again with the growth message, then
re-apply. This proves the guard is pinning the fix and not passing incidentally.

- [ ] **Step 5: Commit**

```bash
git add app/controllers/projects_controller.rb
git commit -m "perf(projects): eager-load rich text bodies on the project page

14 queries at 3 build-log entries and 26 at 15 -> a flat 12. has_rich_text :body means
Action Text loads each body separately unless :rich_text_body is in the includes; the
overhaul that added rich text never extended the eager load."
```

---

## Task 3: Wire Solid Cache (S9) — the rate limiter's prerequisite

**Files:**
- Modify: `config/environments/production.rb:85-86`
- Modify: `config/environments/test.rb:23`
- Modify: `CLAUDE.md` (§4 stack table)

- [ ] **Step 1: Verify the current state so the change is provably a change**

```bash
RAILS_ENV=production SECRET_KEY_BASE=x DATABASE_URL=sqlite3:tmp/x.sqlite3 \
  bin/rails runner 'puts Rails.application.config.cache_store.inspect'
```

Expected before the fix: `[:file_store, ".../tmp/cache/"]` — container-local, wiped every deploy.

- [ ] **Step 2: Switch production to Solid Cache**

The substrate is already complete: `solid_cache` is in `Gemfile:39`, `config/cache.yml`
configures it, `config/database.yml` declares the `cache` role, and `db/cache_schema.rb`
provisions the table. Only this line is missing.

In `config/environments/production.rb`, replace lines 85-86:

```ruby
  # Replace the default in-process memory cache store with a durable alternative.
  # config.cache_store = :mem_cache_store
```

with:

```ruby
  # Solid Cache, backed by its own database (the `cache` entry in database.yml, schema in
  # db/cache_schema.rb, tuning in config/cache.yml). Without this line Rails falls back to a
  # FileStore in the container's tmp/ — wiped by every Kamal deploy and invisible to a second
  # container. Solid Queue and Solid Cable were wired below and above; this was the third that
  # got missed. Rate limiting (see the Users:: controllers) counts in this store, so it needs
  # to be durable and shared.
  config.cache_store = :solid_cache_store
```

- [ ] **Step 3: Give the test environment a real store for rate limiting only**

`config.cache_store` stays `:null_store` in test — general caching should remain off so tests
never see a stale read. But `rate_limiting` does `count = store.increment(...)` and then
`if count && count > to`, and **`NullStore#increment` returns nil**, so a throttle backed by the
null store silently never fires. `config.action_controller.cache_store` is the exact knob for
this: it gives rate limiting a working store without turning on caching anywhere else.

In `config/environments/test.rb`, after line 23 (`config.cache_store = :null_store`), add:

```ruby
  # Rate limiting counts in config.action_controller.cache_store, which defaults to
  # config.cache_store — and NullStore#increment returns nil, which makes
  # ActionController's `if count && count > to` silently never fire. A throttle test would
  # then fail for the wrong reason and, worse, a "normal requests still work" test would pass
  # whether or not the throttle exists at all. Give rate limiting a real store; leave general
  # caching off.
  config.action_controller.cache_store = :memory_store
```

- [ ] **Step 4: Verify both ends**

```bash
RAILS_ENV=production SECRET_KEY_BASE=x DATABASE_URL=sqlite3:tmp/x.sqlite3 \
  bin/rails runner 'puts Rails.application.config.cache_store.inspect; puts Rails.cache.class'
```

Expected: `:solid_cache_store` and `SolidCache::Store`.

```bash
bin/rails runner -e test 'puts ActionController::Base.cache_store.class; puts Rails.cache.class'
```

Expected: `ActiveSupport::Cache::MemoryStore` and `ActiveSupport::Cache::NullStore`.

- [ ] **Step 5: Full suite — a cache-store change can surface a hidden cache dependency**

```bash
bin/rails db:test:prepare test 2>&1 | tail -3
```

Expected: 1690 runs (plus Task 1's 6) / 0 failures.

- [ ] **Step 6: Correct the CLAUDE.md drift**

§4's stack table claims "Rails 8 (Solid Queue/Cache/Cable)". That was aspirational for the Cache
third until this task. Leave the claim, and append to the same row or its note:

```
| Backend | **Rails 8** (Solid Queue/Cache/Cable — Cache was provisioned but not wired until 2026-07-30; `config.cache_store` had been left at the scaffold default, which resolved to a container-local FileStore) |
```

- [ ] **Step 7: Commit**

```bash
git add config/environments/production.rb config/environments/test.rb CLAUDE.md
git commit -m "fix(cache): switch on Solid Cache — provisioned, never wired

The gem, config/cache.yml, the database.yml role and db/cache_schema.rb were all in
place; config.cache_store was still the scaffold comment, so production resolved to a
FileStore in the container's tmp/ (wiped every deploy). Queue and Cable were wired; Cache
was the one that got missed.

Test env gets config.action_controller.cache_store = :memory_store, because NullStore
increment returns nil and a throttle on it can never fire."
```

---

## Task 4: Rate-limit the auth entry points (S3)

Depends on Task 3. The mechanism, the store choice, and the mutation check in this task were all
verified against this codebase before the plan was written; the numbers below are the spiked
values.

**Files:**
- Create: `test/integration/web/auth_throttle_test.rb`
- Modify: `app/controllers/users/sessions_controller.rb`
- Modify: `app/controllers/users/passwords_controller.rb`
- Modify: `app/controllers/users/confirmations_controller.rb`
- Modify: `app/controllers/users/registrations_controller.rb`

- [ ] **Step 1: Write the failing tests**

Create `test/integration/web/auth_throttle_test.rb`:

```ruby
require "test_helper"

module Web
  # Per-IP throttles on the four unauthenticated auth entry points.
  #
  # WHAT THIS ADDS OVER DEVISE :lockable, WHICH IS ALREADY ON: lockable bounds guesses against
  # ONE account (10 attempts, then an hour). It does nothing about spraying one attempt each
  # across many accounts, nothing about password-reset and confirmation-resend each sending a
  # real email per POST, and nothing about the flip side of lockable — anyone who knows an
  # address can lock that account for an hour, repeatedly. Per-IP limiting is what makes
  # lockable a safeguard rather than a weapon.
  #
  # THE COUNTER LIVES IN config.action_controller.cache_store AND IS SHARED ACROSS TESTS,
  # because `by:` defaults to request.remote_ip and every integration test comes from
  # 127.0.0.1. Clear it in setup or the second test in the file starts already throttled.
  class AuthThrottleTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      ActionController::Base.cache_store.clear
      @user = User.create!(email: "throttled@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
    end

    test "the store backing rate limits is real, not a null store" do
      # Guards the config change in Task 3. With a NullStore, increment returns nil and every
      # throttle in this file becomes a no-op that no other assertion here would notice.
      assert_not_kind_of ActiveSupport::Cache::NullStore, ActionController::Base.cache_store
    end

    test "login attempts past the limit are refused" do
      10.times do
        post user_session_path, params: { user: { email: @user.email, password: "wrong" } }
        assert_response :unprocessable_entity, "attempts under the limit get the normal answer"
      end

      post user_session_path, params: { user: { email: @user.email, password: "wrong" } }
      assert_redirected_to new_user_session_path
      assert_match(/too many/i, flash[:alert].to_s)
    end

    test "a throttled IP cannot log in even with the CORRECT password" do
      # The throttle must gate the endpoint, not just failures — otherwise an attacker who
      # guesses correctly on attempt 11 is let through.
      11.times do
        post user_session_path, params: { user: { email: @user.email, password: "wrong" } }
      end
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      assert_redirected_to new_user_session_path

      get files_path
      assert_redirected_to new_user_session_path, "must not be signed in"
    end

    test "password-reset requests past the limit send no further mail" do
      5.times do
        post user_password_path, params: { user: { email: @user.email } }
      end
      assert_no_emails do
        post user_password_path, params: { user: { email: @user.email } }
      end
      assert_match(/too many/i, flash[:alert].to_s)
    end

    test "confirmation resends past the limit send no further mail" do
      unconfirmed = User.create!(email: "pending@example.com", password: PASSWORD)
      5.times do
        post user_confirmation_path, params: { user: { email: unconfirmed.email } }
      end
      assert_no_emails do
        post user_confirmation_path, params: { user: { email: unconfirmed.email } }
      end
    end

    test "signups past the limit create no further accounts" do
      5.times do |i|
        post user_registration_path, params: { user: {
          email: "new#{i}@example.com", password: PASSWORD, password_confirmation: PASSWORD
        } }
      end
      assert_no_difference "User.count" do
        post user_registration_path, params: { user: {
          email: "blocked@example.com", password: PASSWORD, password_confirmation: PASSWORD
        } }
      end
    end
  end
end
```

- [ ] **Step 2: Run and confirm they fail**

```bash
bin/rails test test/integration/web/auth_throttle_test.rb
```

Expected: the "real, not a null store" test **passes** (Task 3 did that), and the other five
**fail** — the 11th login returns 422 instead of a redirect, and the extra POSTs still send mail
and still create users.

- [ ] **Step 3: Add the throttles**

`app/controllers/users/sessions_controller.rb` — replace the whole file:

```ruby
# Devise session controller. Default behavior (authenticate email+password, reject
# unconfirmed via :confirmable, reject locked via :lockable). Subclassed so we can keep our
# routing namespace and add hooks later.
module Users
  class SessionsController < Devise::SessionsController
    # Per-IP, ON TOP OF Devise :lockable, which is per-ACCOUNT. Lockable stops 10 guesses at
    # one address; this stops one guess each at ten thousand addresses, and it stops an
    # attacker from locking a known account over and over. Counts in
    # config.action_controller.cache_store (Solid Cache in production).
    rate_limit to: 10, within: 3.minutes, only: :create,
               with: -> { redirect_to new_user_session_path, alert: "Too many sign-in attempts. Try again in a few minutes." }
  end
end
```

`app/controllers/users/passwords_controller.rb` — replace the whole file:

```ruby
module Users
  class PasswordsController < Devise::PasswordsController
    # Each POST sends a real email, so an unthrottled endpoint is a mail cannon aimed at
    # whichever address the attacker names — and a fast way to get our sending domain listed.
    rate_limit to: 5, within: 15.minutes, only: :create,
               with: -> { redirect_to new_user_password_path, alert: "Too many reset requests. Try again later." }
  end
end
```

`app/controllers/users/confirmations_controller.rb` — replace the whole file:

```ruby
module Users
  class ConfirmationsController < Devise::ConfirmationsController
    # Same reasoning as password reset: one POST, one email.
    rate_limit to: 5, within: 15.minutes, only: :create,
               with: -> { redirect_to new_user_confirmation_path, alert: "Too many confirmation requests. Try again later." }
  end
end
```

`app/controllers/users/registrations_controller.rb` — add the throttle immediately after the
class line, leaving the existing blank-password guard untouched:

```ruby
module Users
  class RegistrationsController < Devise::RegistrationsController
    # Bounds automated signup floods. Deliberately looser than the others: a household or an
    # office behind one NAT address may legitimately create several accounts in a sitting.
    rate_limit to: 5, within: 15.minutes, only: :create,
               with: -> { redirect_to new_user_registration_path, alert: "Too many sign-up attempts. Try again later." }

    # A human web sign-up MUST supply a password. …(existing comment and #create unchanged)
```

- [ ] **Step 4: Run and confirm green**

```bash
bin/rails test test/integration/web/auth_throttle_test.rb
```

Expected: **6 runs, 0 failures.**

- [ ] **Step 5: Mutation-check each throttle**

Delete the `rate_limit` line from `sessions_controller.rb`, rerun, and confirm the failure is
`Expected response to be a <3XX: redirect>, but was a <422: Unprocessable Content>`. Restore.
Repeat for one of the mail throttles and confirm `assert_no_emails` fails. This is the step that
proves the tests are not passing for an unrelated reason.

- [ ] **Step 6: Confirm the existing auth suite still passes**

The throttle limits are above what any existing test drives, but verify rather than assume — the
counter is shared per IP across a worker's tests:

```bash
bin/rails test test/integration/web/devise_auth_flow_test.rb test/integration/web/omniauth_callback_test.rb
```

Expected: 0 failures. If a pre-existing test now trips a throttle, add
`ActionController::Base.cache_store.clear` to that file's `setup` rather than raising the limit.

- [ ] **Step 7: Commit**

```bash
git add test/integration/web/auth_throttle_test.rb app/controllers/users/
git commit -m "feat(auth): per-IP rate limits on login, reset, confirm and signup

Devise :lockable already bounds guesses against ONE account. Unbounded before this:
spraying across many accounts, reset/confirm each sending real mail per POST, and locking
a known account on demand — lockable's own flip side.

The 'real, not a null store' test is deliberate: NullStore#increment returns nil, so
ActionController's `if count && count > to` would make every throttle here a silent no-op
that no other assertion would catch."
```

---

## Task 5: Close user enumeration (S2)

**Files:**
- Create: `test/integration/web/account_enumeration_test.rb`
- Modify: `config/initializers/devise.rb:93`

- [ ] **Step 1: Write the failing test**

Create `test/integration/web/account_enumeration_test.rb`:

```ruby
require "test_helper"

module Web
  # An unregistered email must be indistinguishable from a registered one. Without
  # config.paranoid, Devise says "not found" for an unknown address and "invalid password" for
  # a known one — which turns both login and password reset into an oracle for whether an
  # address has an account here. That is the input to credential stuffing and to targeted
  # phishing, and reset is the cleaner oracle of the two because it needs no password guess.
  class AccountEnumerationTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      ActionController::Base.cache_store.clear
      User.create!(email: "known@example.com", password: PASSWORD, confirmed_at: Time.current)
    end

    test "a reset request for an unknown email answers exactly like a known one" do
      post user_password_path, params: { user: { email: "known@example.com" } }
      known_status = response.status
      known_location = response.location
      known_flash = flash[:notice].to_s

      post user_password_path, params: { user: { email: "nobody@example.com" } }

      assert_equal known_status, response.status
      assert_equal known_location, response.location
      assert_equal known_flash, flash[:notice].to_s,
                   "the response must not reveal whether the address has an account"
    end

    test "a reset request for an unknown email still sends no mail" do
      # Indistinguishable to the requester, but we must not mail a stranger either.
      assert_no_emails do
        post user_password_path, params: { user: { email: "nobody@example.com" } }
      end
    end

    test "login with an unknown email answers exactly like a wrong password" do
      post user_session_path, params: { user: { email: "known@example.com", password: "wrong" } }
      known_status = response.status
      known_flash = flash[:alert].to_s

      post user_session_path, params: { user: { email: "nobody@example.com", password: "wrong" } }

      assert_equal known_status, response.status
      assert_equal known_flash, flash[:alert].to_s
    end
  end
end
```

- [ ] **Step 2: Run and confirm failure**

```bash
bin/rails test test/integration/web/account_enumeration_test.rb
```

Expected: the two "answers exactly like" tests fail on the flash comparison — the known address
gets "You will receive an email…" while the unknown one gets an error naming the field. The
`assert_no_emails` test should already pass.

- [ ] **Step 3: Enable paranoid mode**

In `config/initializers/devise.rb`, line 93, change:

```ruby
  # config.paranoid = true
```

to:

```ruby
  # ON. Devise otherwise distinguishes "no such account" from "wrong password" on login and
  # on password reset, which confirms to anyone asking whether an address is registered here.
  # Pinned by test/integration/web/account_enumeration_test.rb. Note this deliberately makes
  # the reset flow LESS helpful to a user who mistyped their address — that is the trade, and
  # it is the standard one.
  config.paranoid = true
```

- [ ] **Step 4: Run the enumeration test, then the whole auth surface**

```bash
bin/rails test test/integration/web/account_enumeration_test.rb
bin/rails test test/integration/web/devise_auth_flow_test.rb
```

Expected: enumeration 3 runs / 0 failures; `devise_auth_flow_test` 12 runs / 0 failures.

**What to expect and why.** `devise_auth_flow_test` asserts status codes and redirects, not
flash copy — checked while planning — so paranoid mode should not disturb it. If a test *does*
fail on a message, the message is the thing that changed on purpose: update the assertion, do
not revert the config.

- [ ] **Step 5: Mutation-check**

Comment `config.paranoid` back out, confirm two enumeration tests go red, restore.

- [ ] **Step 6: Commit**

```bash
git add config/initializers/devise.rb test/integration/web/account_enumeration_test.rb
git commit -m "fix(auth): paranoid mode — stop confirming which emails have accounts

Login and password reset distinguished 'no such account' from 'wrong password', so either
endpoint answered 'is this address registered here?' for anyone who asked. Reset was the
cleaner oracle: no password guess needed."
```

---

## Task 6: Require the current password to delete an account (S10)

**Files:**
- Create: `test/integration/web/account_settings_test.rb`
- Modify: `app/controllers/users/registrations_controller.rb`
- Modify or create: `app/views/devise/registrations/edit.html.erb`

- [ ] **Step 1: Confirm the current behaviour first-hand**

Before changing anything, see it. `DELETE /users` today needs only the session cookie:

```bash
bin/rails runner -e test '
  u = User.create!(email: "probe@x.com", password: "correct horse battery staple", confirmed_at: Time.current)
  u.maker_projects.create!(name: "Precious", status: "active")
  puts "projects before: #{Maker::Project.count}"
'
```

The measured result at plan time: one request with **no password** took `users=1 projects=1
nodes=1 tasks=1` to all zero, 303 to `/`. The cascade is complete and correct (31
`dependent: :destroy` associations); what is missing is the confirmation.

- [ ] **Step 2: Write the failing tests**

Create `test/integration/web/account_settings_test.rb`:

```ruby
require "test_helper"

module Web
  # The account-settings surface: edit, update, cancel, and destroy. None of these four actions
  # was driven by any test before this file, and destroy is irreversible — one request took the
  # account and everything cascading off it (projects, nodes, tasks, build log, attachments,
  # previews, sheets, devices) with no password and no confirmation.
  class AccountSettingsTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze
    NEW_PASSWORD = "a different correct horse".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      ActionController::Base.cache_store.clear
      @user = User.create!(email: "owner@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    # --- edit ------------------------------------------------------------------

    test "the settings page renders for a signed-in user" do
      get edit_user_registration_path
      assert_response :success
    end

    test "the settings page requires a session" do
      delete destroy_user_session_path
      get edit_user_registration_path
      assert_redirected_to new_user_session_path
    end

    test "cancel renders for a signed-in user" do
      get cancel_user_registration_path
      assert_response :redirect
    end

    # --- update ----------------------------------------------------------------

    test "changing the password requires the current one" do
      patch user_registration_path, params: { user: {
        password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD, current_password: "wrong"
      } }
      assert_response :unprocessable_entity
      assert @user.reload.valid_password?(PASSWORD), "the password must not have changed"
    end

    test "changing the password with the current one works" do
      patch user_registration_path, params: { user: {
        password: NEW_PASSWORD, password_confirmation: NEW_PASSWORD, current_password: PASSWORD
      } }
      assert @user.reload.valid_password?(NEW_PASSWORD)
    end

    # --- destroy ---------------------------------------------------------------

    test "deleting the account REQUIRES the current password" do
      @user.maker_projects.create!(name: "Precious", status: "active")

      assert_no_difference [ "User.count", "Maker::Project.count" ] do
        delete user_registration_path
      end
      assert User.exists?(@user.id), "a request with no password must not delete the account"
    end

    test "a wrong password does not delete the account" do
      assert_no_difference "User.count" do
        delete user_registration_path, params: { user: { current_password: "wrong" } }
      end
      assert User.exists?(@user.id)
    end

    test "the correct password deletes the account and everything it owns" do
      project = @user.maker_projects.create!(name: "Precious", status: "active")
      @user.nodes.create!(node_id: "gone", name: "gone.stl", kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)
      project.tasks.create!(user: @user, title: "t")

      delete user_registration_path, params: { user: { current_password: PASSWORD } }

      assert_not User.exists?(@user.id)
      assert_equal 0, Maker::Project.where(user_id: @user.id).count
      assert_equal 0, Node.where(user_id: @user.id).count
      assert_equal 0, Maker::Task.where(user_id: @user.id).count
    end

    test "deleting an account leaves other users untouched" do
      other = User.create!(email: "bystander@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      other.maker_projects.create!(name: "Theirs", status: "active")

      delete user_registration_path, params: { user: { current_password: PASSWORD } }

      assert User.exists?(other.id)
      assert_equal 1, Maker::Project.where(user_id: other.id).count
    end
  end
end
```

- [ ] **Step 3: Run and confirm which fail**

```bash
bin/rails test test/integration/web/account_settings_test.rb
```

Expected: the two `destroy`-guard tests fail (the account is deleted anyway). The update tests
should already pass — Devise requires `current_password` for a password change by default. The
"correct password deletes" and "leaves other users untouched" tests should already pass too;
they are there so the fix cannot over-correct into blocking deletion entirely.

- [ ] **Step 4: Require the password on destroy**

In `app/controllers/users/registrations_controller.rb`, add a `destroy` override after `create`:

```ruby
    # Devise's #destroy is `resource.destroy` with no confirmation. Account deletion here
    # cascades through 31 `dependent: :destroy` associations — the whole library catalog,
    # projects, build log, previews, devices — and there is no undo. Require the current
    # password, which is the same bar Devise already sets for merely CHANGING a password.
    #
    # NOT a `before_action`: the failure has to re-render the settings page with an error, and
    # that needs the same resource setup #edit does.
    def destroy
      if resource.valid_password?(params.dig(:user, :current_password).to_s)
        super
      else
        resource.errors.add(:current_password,
                            params.dig(:user, :current_password).blank? ? :blank : :invalid)
        render :edit, status: :unprocessable_entity
      end
    end
```

- [ ] **Step 5: Add the password field to the delete form**

The form must send `user[current_password]` or the fix makes deletion impossible through the UI.
Check whether the view exists:

```bash
ls app/views/devise/registrations/edit.html.erb
```

If it does not exist, Devise is rendering its gem-bundled view and you must generate a local
copy to edit:

```bash
bin/rails generate devise:views:registrations
```

Then in `app/views/devise/registrations/edit.html.erb`, find the "Cancel my account" block and
replace its `button_to`/`link_to` with a form that carries the password:

```erb
<div class="account-delete">
  <h3>Delete this account</h3>
  <p>
    This removes your account and everything in it — projects, the file catalog, tasks,
    build log, previews and paired devices. It cannot be undone.
  </p>
  <%= form_with url: registration_path(resource_name), method: :delete do |f| %>
    <%= f.label :current_password, "Confirm your password to delete" %>
    <%= f.password_field "user[current_password]", autocomplete: "current-password", required: true %>
    <%= f.submit "Delete my account", data: { turbo_confirm: "Permanently delete your account and all of its data?" } %>
  <% end %>
</div>
```

- [ ] **Step 6: Run and confirm green**

```bash
bin/rails test test/integration/web/account_settings_test.rb
```

Expected: **9 runs, 0 failures.**

- [ ] **Step 7: Mutation-check**

Delete the `destroy` override, rerun, and confirm the two guard tests go red. Restore.

- [ ] **Step 8: Commit**

```bash
git add app/controllers/users/registrations_controller.rb app/views/devise/registrations/edit.html.erb test/integration/web/account_settings_test.rb
git commit -m "fix(auth): require the current password to delete an account

Measured before: DELETE /users carrying only a session cookie took users=1 projects=1
nodes=1 tasks=1 to zero. The cascade itself is right — 31 dependent: :destroy — so the
gap was the confirmation, on the one action with no undo. Devise already demands the
current password to CHANGE a password; deleting everything should not be cheaper.

Also the first tests for edit/update/cancel/destroy, none of which was driven before."
```

---

## Task 7: Env-gated SSL (S1)

**Files:**
- Modify: `config/environments/production.rb:27-34`

- [ ] **Step 1: Make the change**

**This must be env-gated, not simply enabled.** The three Unraid backends are reached by IP over
plain HTTP on the LAN; an unconditional `force_ssl` redirects them to a URL nothing serves and
takes all three down. That is almost certainly why the lines were left commented — the fix makes
the intent explicit rather than flipping a switch.

In `config/environments/production.rb`, replace lines 27-34:

```ruby
  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
```

with:

```ruby
  # HTTPS, opt-in per deployment via FORCE_SSL.
  #
  # WHY GATED AND NOT SIMPLY ON: this app runs in two shapes. The internet-facing host serves
  # HTTPS behind a terminating proxy and wants all three effects — assume_ssl so Rails believes
  # the proxy, force_ssl for the http->https redirect and HSTS, and (the one that matters most)
  # the Secure flag on the session cookie, which is what force_ssl actually sets. The Unraid
  # backends are reached by IP over plain HTTP on the LAN, and an unconditional force_ssl would
  # redirect them somewhere nothing listens — all three down, from a security improvement.
  #
  # SET FORCE_SSL=1 ON ANY HOST REACHABLE FROM THE INTERNET. Without it the session cookie is
  # sent on plain-HTTP requests to the same host.
  if ENV["FORCE_SSL"].present?
    config.assume_ssl = true
    config.force_ssl  = true
    # Kamal's proxy health-checks over plain HTTP inside the container network; redirecting /up
    # to https would fail the check and roll the deploy back.
    config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }
  end
```

- [ ] **Step 2: Verify both branches resolve as intended**

```bash
RAILS_ENV=production SECRET_KEY_BASE=x DATABASE_URL=sqlite3:tmp/x.sqlite3 \
  bin/rails runner 'puts "force_ssl=#{Rails.application.config.force_ssl.inspect} assume_ssl=#{Rails.application.config.assume_ssl.inspect}"'
```

Expected: `force_ssl=false assume_ssl=false` (or nil) — the LAN default is unchanged.

```bash
FORCE_SSL=1 RAILS_ENV=production SECRET_KEY_BASE=x DATABASE_URL=sqlite3:tmp/x.sqlite3 \
  bin/rails runner 'puts "force_ssl=#{Rails.application.config.force_ssl.inspect} assume_ssl=#{Rails.application.config.assume_ssl.inspect}"'
```

Expected: `force_ssl=true assume_ssl=true`.

- [ ] **Step 3: Record the operational requirement**

Add to `docs/DEPLOY.md`, in whichever section lists per-host environment variables:

```markdown
### `FORCE_SSL`

Set to any non-empty value on a host reachable from the internet. Turns on `assume_ssl`
(trust the terminating proxy's `X-Forwarded-Proto`), `force_ssl` (http→https redirect + HSTS +
**the Secure flag on the session cookie**), and an exclusion so kamal-proxy's plain-HTTP `/up`
health check still passes.

**Leave it unset on the Unraid backends.** They are reached by IP over plain HTTP on the LAN;
with `FORCE_SSL` set they would redirect every request to a URL nothing serves.
```

- [ ] **Step 4: Full suite (the test env is untouched, so this is a regression check only)**

```bash
bin/rails db:test:prepare test 2>&1 | tail -3
```

Expected: 0 failures.

- [ ] **Step 5: Commit**

```bash
git add config/environments/production.rb docs/DEPLOY.md
git commit -m "fix(security): env-gated force_ssl/assume_ssl (FORCE_SSL=1)

Neither was enabled anywhere, so the internet-facing host had no HSTS, no http->https
redirect, and — the one that matters — no Secure flag on the session cookie, which is what
force_ssl sets. Gated rather than switched on because the Unraid backends are plain HTTP
by IP on the LAN and would redirect to nothing."
```

---

## Task 8: Raise the password floor (S7)

**Files:**
- Modify: `config/initializers/devise.rb:183`
- Modify: `test/integration/web/devise_auth_flow_test.rb` (add one test)

- [ ] **Step 1: Write the failing test**

Append to the sign-up section of `test/integration/web/devise_auth_flow_test.rb`:

```ruby
    test "sign up rejects a password below the length floor" do
      short = "abc12345" # 8 chars — under the 10-char floor, over Devise's old 6
      assert_no_difference "User.count" do
        post user_registration_path, params: { user: {
          email: "shortpw@example.com", password: short, password_confirmation: short
        } }
      end
      assert_response :unprocessable_entity
    end
```

- [ ] **Step 2: Run and confirm it fails**

```bash
bin/rails test test/integration/web/devise_auth_flow_test.rb -n /length_floor/
```

Expected: FAIL — 8 characters is currently accepted, so a user is created and the response is a
redirect.

- [ ] **Step 3: Raise the floor**

In `config/initializers/devise.rb`, line 183, change:

```ruby
  config.password_length = 6..128
```

to:

```ruby
  # 10, not 6. Six is below any current guidance. Deliberately NOT paired with composition
  # rules (a symbol, a digit, mixed case): NIST deprecated those — they push users toward
  # predictable substitutions while shrinking the practical keyspace. Length plus, eventually,
  # a breached-password check is the current advice; the breach check is tracked in
  # docs/OPEN-WORK.md rather than done here, because it needs a network dependency decision.
  config.password_length = 10..128
```

- [ ] **Step 4: Run and confirm green, then the whole suite**

```bash
bin/rails test test/integration/web/devise_auth_flow_test.rb
bin/rails db:test:prepare test 2>&1 | tail -3
```

Expected: both 0 failures. **If other tests fail, they are using a short password fixture** —
the shared `PASSWORD = "correct horse battery staple"` is 28 characters and fine, but check for
literals like `"password"` (8) and lengthen them.

- [ ] **Step 5: Commit**

```bash
git add config/initializers/devise.rb test/integration/web/devise_auth_flow_test.rb
git commit -m "fix(auth): raise the password floor from 6 to 10

No composition rules added, deliberately — NIST deprecates them in favour of length plus a
breach check."
```

---

## Task 9: Content-Security-Policy, report-only first (S4)

Report-only is not timidity, it is the only safe first move: this app loads a vendored
Jspreadsheet grid, the Lexxy rich-text editor, and an importmap, and `javascript_importmap_tags`
emits an **inline** `<script type="importmap">` that a naive `script-src 'self'` blocks outright,
taking all JavaScript down.

**Files:**
- Modify: `config/initializers/content_security_policy.rb`

- [ ] **Step 1: Survey what the policy has to allow**

```bash
grep -rn "<script" app/views/ | grep -v "javascript_importmap_tags\|javascript_include_tag"
grep -rho 'style="' app/views/ | wc -l
```

At plan time: no real inline `<script>` (the two hits are prose inside comments) and exactly one
inline `style=`. So `script-src 'self'` plus a nonce for the importmap is realistic, and
`style-src` needs `'unsafe-inline'` for now because the vendored grid and editor inject styles at
runtime.

- [ ] **Step 2: Write the report-only policy**

Replace the whole of `config/initializers/content_security_policy.rb`:

```ruby
# Be sure to restart your server when you modify this file.
#
# REPORT-ONLY, ON PURPOSE, FOR NOW.
#
# This is defence in depth rather than the primary control: the obvious stored-XSS route in an
# app that serves user-uploaded bytes is already closed in the right place —
# FilesController#blob serves `inline` only for a raster allowlist plus application/pdf and
# forces everything else (SVG and HTML by name) to `attachment` with nosniff. Action Text
# sanitises rich text and Maker::TextOnlyRichText strips attachments server-side. CSP is here to
# catch the NEXT inline-serving mistake, not today's.
#
# WHY NOT ENFORCING YET: the app ships a vendored Jspreadsheet grid, the Lexxy editor, and an
# importmap. `javascript_importmap_tags` emits an INLINE <script type="importmap">, so an
# enforcing `script-src :self` with no nonce takes every page's JavaScript down at once. Run
# report-only, read the violations from the browser console on the grid page, the editor, the
# file browser and the /tools addons, then tighten and flip. Tracked in docs/OPEN-WORK.md.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.font_src    :self, :data
    # :data for inline preview thumbnails; :blob for client-side generated SVG in the addons.
    policy.img_src     :self, :data, :blob
    policy.object_src  :none
    policy.script_src  :self
    # 'unsafe-inline' because the vendored grid and the editor inject style attributes at
    # runtime. Narrowing this is the follow-up, and it is why style-src is NOT in the nonce
    # directives below — a nonce plus 'unsafe-inline' means the nonce wins and inline styles
    # break, which is the opposite of what we want while measuring.
    policy.style_src   :self, :unsafe_inline
    policy.base_uri    :self
    policy.form_action :self
    policy.frame_ancestors :none
  end

  # The importmap tag is inline and needs the nonce. session.id is stable per session, which is
  # what Rails' own template recommends.
  config.content_security_policy_nonce_generator = ->(request) { request.session.id.to_s }
  config.content_security_policy_nonce_directives = %w[script-src]

  # Measure, do not enforce. Flip this to false only after the violation list is empty across
  # the grid page, the rich-text editor, the file browser and all three /tools addons.
  config.content_security_policy_report_only = true
end
```

- [ ] **Step 3: Verify the header is present and is the report-only one**

```bash
bin/rails test test/integration/web/files_flow_test.rb
```

Then confirm the header by driving a request:

```bash
bin/rails runner -e test '
  include Rack::Test::Methods rescue nil
  app = Rails.application
  env = Rack::MockRequest.env_for("/users/sign_in")
  status, headers, _ = app.call(env)
  puts "status=#{status}"
  puts "report-only: #{headers["content-security-policy-report-only"].inspect}"
  puts "enforcing:   #{headers["content-security-policy"].inspect}"
'
```

Expected: the report-only header is populated and the enforcing header is nil. **If the enforcing
one is set instead, `report_only` did not take effect — stop, do not deploy.**

- [ ] **Step 4: Full suite**

```bash
bin/rails db:test:prepare test 2>&1 | tail -3
```

Expected: 0 failures. A report-only policy cannot break a request, so a failure here means the
initializer itself is wrong.

- [ ] **Step 5: Commit**

```bash
git add config/initializers/content_security_policy.rb
git commit -m "feat(security): report-only Content-Security-Policy

Report-only because javascript_importmap_tags emits an inline <script> and the app ships a
vendored grid and editor — an enforcing script-src would take all JS down. Read violations
on the grid page, the editor, the file browser and the /tools addons before flipping.

Defence in depth: the inline-serving XSS route is already closed in FilesController#blob."
```

---

## Task 10: Unique index on `maker_file_attachments` (S6)

The application already prevents duplicates — measured, two sequential POSTs of the same node to
the same project create one row. The residual gap is TOCTOU under genuinely concurrent requests
(a double-click, a retried `fetch`). So this is a constraint, and the migration must survive rows
that already violate it.

**Files:**
- Create: `db/migrate/<timestamp>_add_unique_index_to_maker_file_attachments.rb`
- Create: `test/models/maker/file_attachment_uniqueness_test.rb`

- [ ] **Step 1: Check the live data before writing a migration that could fail on it**

```bash
bin/rails runner '
  dupes = Maker::FileAttachment.group(:user_id, :attachable_type, :attachable_id, :node_id)
                               .having("COUNT(*) > 1").count
  puts "duplicate groups: #{dupes.size}"
  dupes.first(5).each { |k, n| puts "  #{k.inspect} x#{n}" }
'
```

Record the number. Zero is likely and does not remove the need for the dedupe step — the
migration must be safe on the deployed databases too, which this command does not see.

- [ ] **Step 2: Write the failing test**

Create `test/models/maker/file_attachment_uniqueness_test.rb`:

```ruby
require "test_helper"

module Maker
  # The app layer already refuses a duplicate attach (two POSTs of the same node to the same
  # project create one row — measured). This pins the DATABASE constraint, which is what closes
  # the remaining window: two concurrent requests both passing the app-level check before either
  # commits. A double-clicked button is enough.
  class FileAttachmentUniquenessTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "uniq@example.com", confirmed_at: Time.current,
                           omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "P", status: "active")
      @user.nodes.create!(node_id: "n1", name: "n1.stl", kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)
    end

    test "the same node cannot be attached to the same project twice" do
      @project.file_attachments.create!(user: @user, node_id: "n1", role: "model")

      assert_raises ActiveRecord::RecordNotUnique do
        # insert_all skips validations and callbacks on purpose: the point is to prove the
        # DATABASE refuses it, which is the only layer a concurrent racer cannot slip past.
        Maker::FileAttachment.insert_all!([ {
          user_id: @user.id, attachable_type: "Maker::Project", attachable_id: @project.id,
          node_id: "n1", role: "model", position: 0,
          created_at: Time.current, updated_at: Time.current
        } ])
      end
    end

    test "the same node CAN be attached to two different projects" do
      other = @user.maker_projects.create!(name: "Q", status: "active")
      @project.file_attachments.create!(user: @user, node_id: "n1", role: "model")
      assert_nothing_raised do
        other.file_attachments.create!(user: @user, node_id: "n1", role: "model")
      end
    end

    test "two different nodes CAN be attached to the same project" do
      @user.nodes.create!(node_id: "n2", name: "n2.stl", kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)
      @project.file_attachments.create!(user: @user, node_id: "n1", role: "model")
      assert_nothing_raised do
        @project.file_attachments.create!(user: @user, node_id: "n2", role: "model")
      end
    end
  end
end
```

- [ ] **Step 3: Run and confirm the first test fails**

```bash
bin/rails test test/models/maker/file_attachment_uniqueness_test.rb
```

Expected: **1 failure of 3** — `ActiveRecord::RecordNotUnique` was not raised, because no
constraint exists yet. The other two must pass now and after, since they are the over-correction
guard.

- [ ] **Step 4: Generate and write the migration**

```bash
bin/rails generate migration AddUniqueIndexToMakerFileAttachments
```

Fill in the generated file:

```ruby
class AddUniqueIndexToMakerFileAttachments < ActiveRecord::Migration[8.1]
  # DEDUPE BEFORE CONSTRAINING. add_index unique: fails outright on a table that already
  # violates it, and this runs against deployed databases this branch cannot inspect. Raw SQL
  # rather than the model, so the migration does not depend on app code that may have moved by
  # the time it runs on an old database — the convention the four existing data migrations in
  # test/models/maker/*_migration_test.rb follow.
  def up
    execute <<~SQL
      DELETE FROM maker_file_attachments
      WHERE id NOT IN (
        SELECT MIN(id) FROM maker_file_attachments
        GROUP BY user_id, attachable_type, attachable_id, node_id
      )
    SQL

    add_index :maker_file_attachments,
              %i[user_id attachable_type attachable_id node_id],
              unique: true,
              name: "index_maker_file_attachments_uniqueness"
  end

  # Reversible only in the index direction. The deleted duplicate rows are NOT restored, and
  # they cannot be — nothing recorded which ids went. Stated rather than implied.
  def down
    remove_index :maker_file_attachments, name: "index_maker_file_attachments_uniqueness"
  end
end
```

- [ ] **Step 5: Migrate and run**

```bash
bin/rails db:migrate
bin/rails test test/models/maker/file_attachment_uniqueness_test.rb
```

Expected: **3 runs, 0 failures.** Confirm `db/schema.rb` picked up the index:

```bash
grep -n "index_maker_file_attachments_uniqueness" db/schema.rb
```

- [ ] **Step 6: Confirm the app-level path still behaves, and does not now 500**

The controller previously relied on its own check. With a DB constraint behind it, a racing
request raises `RecordNotUnique` — verify the existing attach flow still answers cleanly:

```bash
bin/rails test test/integration/web/project_attachments_test.rb test/integration/web/attach_from_files_test.rb test/integration/web/attach_model_bundle_test.rb test/integration/web/attach_auto_move_test.rb
```

Expected: 0 failures. **If any test now sees a 500, the controller needs to rescue
`ActiveRecord::RecordNotUnique` and answer the same way it answers its own duplicate check** —
add that rescue and a test for it before moving on.

- [ ] **Step 7: Full suite, all three legs**

```bash
bin/rails db:test:prepare test 2>&1 | tail -3
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test 2>&1 | tail -3
```

- [ ] **Step 8: Commit**

```bash
git add db/migrate db/schema.rb test/models/maker/file_attachment_uniqueness_test.rb
git commit -m "fix(db): unique index on maker_file_attachments, with a dedupe pass

The app already refuses a duplicate attach (2 POSTs -> 1 row, measured); this closes the
concurrent window where both requests pass the check before either commits. The migration
dedupes first because add_index unique: fails on a table that already violates it, and it
runs against databases this branch cannot inspect.

down() restores the index, not the deleted rows — nothing recorded which ids went."
```

---

## Task 11: The remaining unexercised auth pages (T1)

**Files:**
- Create: `test/integration/web/auth_pages_test.rb`

- [ ] **Step 1: Write the tests**

These are the leftover measured gaps: `passwords#new`, `passwords#edit`, `confirmations#new`,
`registrations#new`, `omniauth_callbacks#passthru`, `models#new`. Smoke-level on purpose — a page
that renders is the whole contract for a form page, and the flows behind them are covered
elsewhere.

Create `test/integration/web/auth_pages_test.rb`:

```ruby
require "test_helper"

module Web
  # The auth and new-record GETs that no test drove. Measured with a
  # process_action.action_controller subscriber over the whole suite: 72 of 85 non-v1 actions
  # were exercised, and these were among the thirteen that were not.
  #
  # Smoke-level deliberately. For a form page, "it renders for the right visitor and redirects
  # the wrong one" is the contract; the POST behind each one is covered in
  # devise_auth_flow_test, account_settings_test and models_flow_test.
  class AuthPagesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      ActionController::Base.cache_store.clear
    end

    test "the sign-up page renders" do
      get new_user_registration_path
      assert_response :success
      assert_select "form[action=?]", user_registration_path
    end

    test "the password-reset request page renders" do
      get new_user_password_path
      assert_response :success
      assert_select "form[action=?]", user_password_path
    end

    test "the confirmation-resend page renders" do
      get new_user_confirmation_path
      assert_response :success
      assert_select "form[action=?]", user_confirmation_path
    end

    test "the password-reset form renders for a valid token" do
      user = User.create!(email: "reset@example.com", password: PASSWORD,
                          confirmed_at: Time.current)
      raw = user.send_reset_password_instructions
      get edit_user_password_path(reset_password_token: raw)
      assert_response :success
      assert_select "form[action=?]", user_password_path
    end

    test "the omniauth passthru endpoint does not 500" do
      # Devise's stub action. It exists to raise a routing error rather than render, so the
      # contract is "not a 500" — a 404 is the correct answer here.
      get user_openid_connect_omniauth_authorize_path
      assert_includes 200..404, response.status
    end

    test "the new-model page renders for a signed-in user" do
      email = "modeler@example.com"
      User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }

      get new_model_path
      assert_response :success
      assert_select "form"
    end

    test "the new-model page requires a session" do
      get new_model_path
      assert_redirected_to new_user_session_path
    end
  end
end
```

- [ ] **Step 2: Run**

```bash
bin/rails test test/integration/web/auth_pages_test.rb
```

Expected: **7 runs, 0 failures.** These pages exist and work; the tests exist so a refactor
cannot silently remove them.

**If `user_openid_connect_omniauth_authorize_path` is a POST-only route**, the GET will 404 —
that is inside the asserted range and fine. If it raises instead, change the assertion to
`assert_raises(AbstractController::ActionNotFound)` and note why.

- [ ] **Step 3: Commit**

```bash
git add test/integration/web/auth_pages_test.rb
git commit -m "test(web): cover the auth and new-record pages nothing drove

Measured, not guessed: a process_action subscriber over the full suite showed 72 of 85
non-v1 actions exercised. These were among the thirteen that were not."
```

---

## Task 12: Build-log photo removal (T1)

**Files:**
- Create: `test/integration/web/entry_photos_test.rb`

- [ ] **Step 1: Write the tests**

`projects/entry_photos#destroy` is a mutating action taking an `:id`, with no test.

Create `test/integration/web/entry_photos_test.rb`:

```ruby
require "test_helper"

module Web
  # Inline photos on a build-log entry. #destroy had no test at all, which for a mutating
  # action that takes an :id is the shape most likely to hide a missing ownership scope.
  class EntryPhotosTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      @user = User.create!(email: "logger@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Logged", status: "active")
      @entry = @project.build_log_entries.create!(user: @user, body: "step one",
                                                  logged_at: Time.current)
      @user.nodes.create!(node_id: "photo1", name: "photo1.png", kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)
    end

    test "attaching an existing image node to an entry" do
      assert_difference "Maker::FileAttachment.count", 1 do
        post build_log_entry_entry_photos_path(@entry), params: { node_id: "photo1" }
      end
      assert_redirected_to project_path(@project)
      assert_equal "image", @entry.file_attachments.last.role
    end

    test "attaching a node that is not in the library is refused" do
      assert_no_difference "Maker::FileAttachment.count" do
        post build_log_entry_entry_photos_path(@entry), params: { node_id: "nope" }
      end
      assert_redirected_to project_path(@project)
    end

    test "removing a photo detaches it" do
      post build_log_entry_entry_photos_path(@entry), params: { node_id: "photo1" }
      att = @entry.file_attachments.last

      assert_difference "Maker::FileAttachment.count", -1 do
        delete entry_photo_path(att)
      end
      assert_redirected_to project_path(@project)
    end

    test "removing a photo leaves the library node alone" do
      post build_log_entry_entry_photos_path(@entry), params: { node_id: "photo1" }
      att = @entry.file_attachments.last

      delete entry_photo_path(att)

      assert @user.nodes.present.exists?(node_id: "photo1"),
             "detaching a photo must not delete the file from the library"
    end

    test "another user cannot remove this entry's photo" do
      post build_log_entry_entry_photos_path(@entry), params: { node_id: "photo1" }
      att = @entry.file_attachments.last

      delete destroy_user_session_path
      other_email = "intruder@example.com"
      User.create!(email: other_email, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: other_email, password: PASSWORD } }

      assert_no_difference "Maker::FileAttachment.count" do
        delete entry_photo_path(att)
      end
      assert Maker::FileAttachment.exists?(att.id)
    end
  end
end
```

- [ ] **Step 2: Confirm the route helper names before running**

```bash
bin/rails routes | grep entry_photo
```

The names used above are `build_log_entry_entry_photos_path` (create) and `entry_photo_path`
(destroy). **If they differ, fix the test to match the routes** — do not change the routes.

- [ ] **Step 3: Run**

```bash
bin/rails test test/integration/web/entry_photos_test.rb
```

Expected: **5 runs, 0 failures.** The cross-user test should pass on the first run —
`entry_photos_controller.rb:26` scopes through `current_user.maker_file_attachments`. That it
passes is the point: the property held and nothing pinned it.

- [ ] **Step 4: Mutation-check the ownership scope**

In `app/controllers/projects/entry_photos_controller.rb`, temporarily change
`current_user.maker_file_attachments.find(params[:id])` to
`Maker::FileAttachment.find(params[:id])`. Rerun: the cross-user test must go red. Restore.

**If it stays green, the test is not testing what it claims** — fix the test, not the controller.

- [ ] **Step 5: Commit**

```bash
git add test/integration/web/entry_photos_test.rb
git commit -m "test(web): cover build-log photo attach and removal

#destroy had no test — a mutating action taking an :id, which is the shape where a missing
ownership scope hides. Mutation-checked: dropping current_user from the lookup turns the
cross-user test red."
```

---

## Task 13: The cross-user authorization sweep (T2)

The property holds today — every web controller scopes through `current_user.*`, and the only two
bare `.find` calls are on already-scoped relations. This task pins it. Today only 8 of ~30 web
test files assert it, so a refactor replacing `current_user.maker_projects.find` with
`Maker::Project.find` would go green across the whole suite.

**Files:**
- Create: `test/integration/web/cross_user_authorization_test.rb`

- [ ] **Step 1: Enumerate what must be covered**

```bash
bin/rails routes | awk '{print $NF}' | grep '#' | grep -v '^v1/' \
  | grep -viE '^(rails|active_storage|action_mailbox|turbo|dev_blobs|users/)' | sort -u
```

Every action in that list which takes a record id and mutates it needs a case below.

- [ ] **Step 2: Write the sweep**

Create `test/integration/web/cross_user_authorization_test.rb`:

```ruby
require "test_helper"

module Web
  # ONE test per mutating web action, driven as a user who does not own the record.
  #
  # WHY A DEDICATED FILE RATHER THAN ONE CASE PER EXISTING FILE: the property is uniform —
  # every controller scopes through current_user.* — so the tests are uniform, and gathering
  # them makes a missing one visible. Scattered across thirty files, "which actions are pinned?"
  # is unanswerable without reading all thirty.
  #
  # EVERY CASE HERE PASSES ON THE FIRST RUN. That is expected and is the point: the property
  # already holds and almost nothing pinned it. Each case is mutation-checked by dropping
  # `current_user` from the corresponding controller lookup and confirming it goes red.
  class CrossUserAuthorizationTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
      ActionController::Base.cache_store.clear

      # The victim owns everything.
      @owner = User.create!(email: "owner@example.com", password: PASSWORD,
                            confirmed_at: Time.current)
      @project = @owner.maker_projects.create!(name: "Theirs", status: "active")
      @task = @project.tasks.create!(user: @owner, title: "their task")
      @entry = @project.build_log_entries.create!(user: @owner, body: "their log",
                                                  logged_at: Time.current)
      @sheet = @project.sheets.create!(user: @owner, name: "their sheet")
      @model = @owner.maker_models.create!(title: "Their Model", slug: "their-model")
      @node = @owner.nodes.create!(node_id: "theirfile", name: "theirs.stl", kind: "file",
                                   size: 1, mtime: 1_700_000_000_000_000_000)
      @attachment = @project.file_attachments.create!(user: @owner, node_id: "theirfile",
                                                      role: "model")
      @run = @model.print_runs.create!(user: @owner, printed_on: Date.current,
                                        outcome: "success")
      @note = @owner.maker_notes.create!(node_id: "theirfile", body: "their note")

      # The intruder is signed in for every test below.
      @intruder = User.create!(email: "intruder@example.com", password: PASSWORD,
                               confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @intruder.email, password: PASSWORD } }
    end

    # A request that must not succeed and must not change anything. Any of 404 / redirect /
    # 4xx is an acceptable answer — WHICH one is each controller's business, and pinning a
    # specific code here would make this file fail on an unrelated copy change. What is NOT
    # acceptable is a 2xx, or a row moving.
    def assert_denied(counted, &request)
      assert_no_difference(counted) do
        request.call
      end
      assert_not response.successful?,
                 "a non-owner got #{response.status} — the record was not scoped to the user"
    end

    # --- projects --------------------------------------------------------------

    test "cannot view another user's project" do
      get project_path(@project)
      assert_not response.successful?
    end

    test "cannot edit another user's project" do
      get edit_project_path(@project)
      assert_not response.successful?
    end

    test "cannot update another user's project" do
      patch project_path(@project), params: { project: { name: "Stolen" } }
      assert_not response.successful?
      assert_equal "Theirs", @project.reload.name
    end

    test "cannot destroy another user's project" do
      assert_denied("Maker::Project.count") { delete project_path(@project) }
    end

    test "cannot unarchive another user's project" do
      @project.update!(status: "archived")
      post unarchive_project_path(@project)
      assert_not response.successful?
      assert_equal "archived", @project.reload.status
    end

    # --- tasks -----------------------------------------------------------------

    test "cannot add a task to another user's project" do
      assert_denied("Maker::Task.count") do
        post project_tasks_path(@project), params: { task: { title: "injected" } }
      end
    end

    test "cannot update another user's task" do
      patch project_task_path(@project, @task), params: { task: { title: "changed" } }
      assert_not response.successful?
      assert_equal "their task", @task.reload.title
    end

    test "cannot destroy another user's task" do
      assert_denied("Maker::Task.count") { delete project_task_path(@project, @task) }
    end

    # --- build log -------------------------------------------------------------

    test "cannot add a build-log entry to another user's project" do
      assert_denied("Maker::BuildLogEntry.count") do
        post project_build_log_entries_path(@project),
             params: { build_log_entry: { body: "injected" } }
      end
    end

    test "cannot destroy another user's build-log entry" do
      assert_denied("Maker::BuildLogEntry.count") do
        delete project_build_log_entry_path(@project, @entry)
      end
    end

    # --- sheets ----------------------------------------------------------------

    test "cannot read another user's sheet" do
      get sheet_path(@sheet)
      assert_not response.successful?
    end

    test "cannot update another user's sheet" do
      patch sheet_path(@sheet), params: { sheet: { name: "stolen" } }
      assert_not response.successful?
      assert_equal "their sheet", @sheet.reload.name
    end

    test "cannot destroy another user's sheet" do
      assert_denied("Maker::Sheet.count") { delete sheet_path(@sheet) }
    end

    test "cannot create a sheet on another user's project" do
      assert_denied("Maker::Sheet.count") do
        post project_sheets_path(@project), params: { sheet: { name: "injected" } }
      end
    end

    # --- attachments -----------------------------------------------------------

    test "cannot attach a file to another user's project" do
      @intruder.nodes.create!(node_id: "mine", name: "mine.stl", kind: "file", size: 1,
                              mtime: 1_700_000_000_000_000_000)
      assert_denied("Maker::FileAttachment.count") do
        post project_attachments_path(@project), params: { node_id: "mine" }
      end
    end

    test "cannot detach another user's attachment" do
      assert_denied("Maker::FileAttachment.count") do
        delete project_attachment_path(@project, @attachment)
      end
    end

    # --- models ----------------------------------------------------------------

    test "cannot view another user's model" do
      get model_path(@model)
      assert_not response.successful?
    end

    test "cannot update another user's model" do
      patch model_path(@model), params: { model: { title: "Stolen" } }
      assert_not response.successful?
      assert_equal "Their Model", @model.reload.title
    end

    test "cannot destroy another user's model" do
      assert_denied("Maker::Model.count") { delete model_path(@model) }
    end

    test "cannot destroy another user's print run" do
      assert_denied("Maker::PrintRun.count") { delete model_print_run_path(@model, @run) }
    end

    # --- files -----------------------------------------------------------------

    test "cannot read another user's file metadata" do
      get file_path(@node.node_id)
      assert_not response.successful?
    end

    test "cannot download another user's bytes" do
      get blob_file_path(@node.node_id)
      assert_not response.successful?
    end

    test "cannot delete another user's file" do
      assert_denied("Node.where(deleted: false).count") { delete file_path(@node.node_id) }
    end

    # --- notes -----------------------------------------------------------------

    test "cannot destroy another user's note" do
      assert_denied("Maker::Note.count") { delete note_path(@note) }
    end
  end
end
```

- [ ] **Step 2b: Fix route-helper names against reality**

```bash
bin/rails routes | grep -E "unarchive|print_run|note|blob|attachment"
```

The helper names above are the expected ones; correct any that differ. **Do not change routes to
match the test.**

- [ ] **Step 3: Run**

```bash
bin/rails test test/integration/web/cross_user_authorization_test.rb
```

Expected: **all green on the first run.** If any case fails, you have found a real
authorization bug — stop, write it up, and fix the controller before continuing.

- [ ] **Step 4: Mutation-check a representative sample**

The sweep is only worth its runtime if the cases can fail. Check **at least three** across
different controllers. For each: drop `current_user` from the lookup, rerun, confirm red,
restore.

| Controller | Change for the check |
|---|---|
| `app/controllers/projects_controller.rb` | `current_user.maker_projects.find_by!(slug:)` → `Maker::Project.find_by!(slug:)` |
| `app/controllers/projects/sheets_controller.rb` | drop `current_user.` from the sheet lookup |
| `app/controllers/models_controller.rb` | drop `current_user.` from the model lookup |

Record in the commit message which ones you checked and that each went red.

- [ ] **Step 5: Full suite, all three legs**

```bash
bin/rails db:test:prepare test 2>&1 | tail -3
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test 2>&1 | tail -3
LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=stub LIBRARY_S3_REGION=us-east-1 \
  LIBRARY_S3_ACCESS_KEY_ID=stub LIBRARY_S3_SECRET_ACCESS_KEY=stub \
  LIBRARY_S3_ENDPOINT=http://stub.invalid bin/rails test 2>&1 | tail -3
```

- [ ] **Step 6: Commit**

```bash
git add test/integration/web/cross_user_authorization_test.rb
git commit -m "test(web): one cross-user denial per mutating web action

The property already holds — every web controller scopes through current_user.* — and
almost nothing pinned it: 8 of ~30 web test files asserted it, so swapping
current_user.maker_projects.find for Maker::Project.find would have gone green.

Mutation-checked on projects, sheets and models: dropping current_user from each lookup
turns the corresponding case red."
```

---

## Task 14: Record the arc and reconcile the docs

**Files:**
- Modify: `docs/STATUS.md`
- Modify: `docs/OPEN-WORK.md`
- Modify: `docs/AUDIT-2026-07-30.md`

- [ ] **Step 1: Take the final suite count on all three legs**

```bash
bin/rails db:test:prepare test 2>&1 | tail -3
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test 2>&1 | tail -3
LIBRARY_BACKEND=s3 LIBRARY_S3_BUCKET=stub LIBRARY_S3_REGION=us-east-1 \
  LIBRARY_S3_ACCESS_KEY_ID=stub LIBRARY_S3_SECRET_ACCESS_KEY=stub \
  LIBRARY_S3_ENDPOINT=http://stub.invalid bin/rails test 2>&1 | tail -3
```

All three must report the same numbers. Baseline was 1690; this plan adds roughly 60 tests.

- [ ] **Step 2: Run every gate**

```bash
bin/ci
```

Expected: every gate passes. `scan` runs bundler-audit, importmap audit and brakeman —
**brakeman may now flag the new `render :edit` in `registrations#destroy`**; if it does, read the
warning and either fix it or add a documented ignore entry with the reasoning, matching the four
existing entries' style.

- [ ] **Step 3: Update the audit's ledger to disposition-actual**

In `docs/AUDIT-2026-07-30.md`, change the Disposition column from intent to outcome — `Fixed
(Task N)` for each closed item, leaving S5, P3, P2 and S8 as they are. **Do not delete the
findings**; the evidence is the point, and a closed finding with its measurement is what stops
the same thing being re-litigated.

- [ ] **Step 4: Prune `docs/OPEN-WORK.md` §1 to what is genuinely still open**

Remove the rows this plan closed. Leave S5 (needs a number), P3 (product decision), P2 and S8.
This is the discipline the document's own preamble demands — a stale open-list spends the next
reader's attention on finished work.

- [ ] **Step 5: Write the STATUS.md entry**

Add a new `## Latest (2026-07-30)` section at the top, demoting the current one to `## Earlier`.
Follow the file's established shape: the suite counts on all three legs, what moved, and — the
part that earns its place — what was **surprising**. Specifically worth recording:

- The query-count guard is the finding, not the N+1. One line fixed the page; the absence of any
  query-count assertion is what let it ship, and `models#show` was flat the whole time with the
  same data shape, so the correct pattern was already in the codebase.
- `NullStore#increment` returns nil, so `ActionController`'s `if count && count > to` makes a
  throttle on the test env's default store a **silent no-op**. A rate-limit test would have
  looked fine while pinning nothing. `config.action_controller.cache_store` is the knob.
- Solid Cache was fully provisioned — gem, `cache.yml`, `database.yml` role, `cache_schema.rb`,
  persistent volume — and one scaffold comment short of being used. Queue and Cable were wired;
  the third was missed, and `CLAUDE.md` §4 claimed all three.
- `DELETE /users` needed no password and took 31 cascading associations with it. The cascade
  itself was completely correct, which is what made the missing confirmation easy to miss.
- Coverage was **measured** with a `process_action` subscriber (72/85), not estimated. Reading
  the controllers would not have produced that list.

- [ ] **Step 6: Commit**

```bash
git add docs/
git commit -m "docs: record the audit-remediation arc

Suite <before> -> <after>, identical on chunk, share and s3. Audit ledger moved to
disposition-actual; OPEN-WORK §1 pruned to what is still open (S5 needs a number, P3 is a
product decision)."
```

---

## Task 15: Verify the whole branch before handing it over

- [ ] **Step 1: Re-read the diff as a reviewer**

```bash
git diff main... --stat
git diff main...
```

Look specifically for: debug leftovers, a `puts`, a commented-out assertion, and any test whose
mutation check you did not actually run.

- [ ] **Step 2: Confirm the two repo-invariant greps still hold**

Both are documented in `CLAUDE.md` and both need their comment filter — the bare forms have
never returned nothing:

```bash
grep -rn "rescue.*NotImplementedError" app lib | grep -v ':[0-9]*: *#'
```

Expected: **nothing.**

```bash
grep -rn "manifest_chunks\|ChunkStore" app/services/maker/ app/models/maker/ app/jobs/maker/ | grep -v ':[0-9]*: *#'
```

Expected: **exactly one line**, `app/services/maker/addons/library_output.rb`. Not zero — that is
documented drift, and one hit is the invariant.

- [ ] **Step 3: Confirm no `*-latest` runner crept into a workflow**

```bash
grep -rn "ubuntu-latest\|macos-latest\|windows-latest" .github/workflows/
```

Expected: **nothing.** GitHub bills hosted runners; self-hosted are free.

- [ ] **Step 4: Full gate run, one more time, from clean**

```bash
bin/ci
```

- [ ] **Step 5: Confirm the coverage claim by re-measuring, not by asserting it**

Re-add the temporary subscriber, run the suite, and re-derive the covered-action count. It should
have risen from 72/85 to at least 83/85 (`dev_blobs#show` and
`omniauth_callbacks#openid_connect` may remain). Create
`config/initializers/zz_action_coverage.rb`:

```ruby
# TEMPORARY audit instrumentation — DELETE before commit.
if ENV["ACTION_COVERAGE_DIR"].present?
  dir = ENV["ACTION_COVERAGE_DIR"]
  FileUtils.mkdir_p(dir)
  ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*, payload|
    File.open(File.join(dir, "hits-#{Process.pid}.txt"), "a") do |f|
      f.puts "#{payload[:controller]}##{payload[:action]}"
    end
  rescue StandardError
    nil
  end
end
```

```bash
ACTION_COVERAGE_DIR=/tmp/cov bin/rails test
cat /tmp/cov/*.txt | sort -u | wc -l
rm config/initializers/zz_action_coverage.rb
```

**Confirm the file is gone before committing** — `git status` must not list it.

- [ ] **Step 6: Hand over**

Use the `superpowers:finishing-a-development-branch` skill to choose between merge, PR, or
further work.

---

## Self-review

**Spec coverage.** Every finding in `docs/AUDIT-2026-07-30.md` maps to a task: S1→7, S2→5, S3→4,
S4→9, S6→10, S7→8, S9→3, S10→6, P1→2, T1→6+11+12, T2→13, T3→1. Deliberately excluded, each with
a stated reason and a home in `docs/OPEN-WORK.md`: **S5** (upload cap — needs a product number; a
wrong one rejects legitimate CAD files), **P3** (folder pagination — a file-browser decision on
its own merits), **P2** (four redundant `Node Load`s — constant, not N+1, worth ~3 round-trips),
**S8** (Active Storage blob URLs are capability-based — standard Rails, accepted).

**Ordering dependencies, all real.** Task 1 before 2, so the fix is verified by a failing test
rather than by a document. Task 3 before 4, because a throttle on a `NullStore` silently never
fires. Task 5 after 4, because both touch the auth flow and paranoid mode changes copy the
throttle tests read.

**Naming consistency, checked.** `rich_text_body` (Action Text's association for
`has_rich_text :body`) in Task 2, matching Task 1's expected 12-query outcome.
`ActionController::Base.cache_store` — the reader — in every test setup; `config.action_controller.cache_store`
— the writer — in Task 3. `trash_index_path` in Task 1, not `trash_path`; the routes name it
`trash_index`. `Maker::PrintRun#printed_on`, not `printed_at`. `Maker::Model#title` + `#slug`,
not `#name`.

**Known soft spots, flagged rather than hidden.** Three tasks depend on route-helper names I read
from `bin/rails routes` but did not exercise (Task 12's `entry_photo_path`, Task 13's
`unarchive_project_path` / `model_print_run_path` / `blob_file_path`, Task 6's Devise view
path). Each has an explicit step to reconcile the test against the real routes, with the
instruction to fix the test and not the routes. Task 9's CSP is report-only precisely because its
blast radius is a whole page's JavaScript, and Task 10 carries an explicit "if this now 500s, add
the rescue" branch, because adding a DB constraint under a controller that was relying on its own
check is the one change here that can turn a handled condition into an unhandled one.
