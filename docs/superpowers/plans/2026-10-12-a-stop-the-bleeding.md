# A — Stop the bleeding on the live surface: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repo `.claude/commands/execute-plan.md` governs how tasks are batched.

**Goal:** Close the internet-facing gaps that `docs/AUDIT-2026-10-12-readiness.md` §1 ranks first, in one PR, so that the next `kamal deploy -d ovh` ships a public host whose proxy routes its own names, whose signup seam is closed everywhere, whose login door is throttled, and whose mail links carry a real host.

**Architecture:** Every change is either a deploy-config edit pinned by `test/deploy_hygiene_test.rb` (which reads the MERGED Kamal config, so overlay semantics are reflected, not re-implemented), a CI-workflow edit pinned by `test/ci_hygiene_test.rb`, or a one-line Rails guard pinned by an integration test that drives the real request. No new abstraction. Each guard is mutation-checked before it is called done.

**Tech Stack:** Rails 8.1, Devise, ActionController `rate_limit` (counts in `config.action_controller.cache_store`, a memory store in test), Kamal 2.12 (`proxy.ssl.certificate_pem` / `private_key_pem` resolve secret NAMES from `.kamal/secrets*`), 1Password via `bin/secret`.

**Deliberately NOT in this PR, and why:**
- A global `config.active_storage.urls_expire_in` — rejected on the record in `app/controllers/public/files_controller.rb:80-84`: it breaks a `loading="lazy"` image on a long-open private page and still checks nothing about the project. The residual (private-page thumbnail URLs never expire) needs a session-authed preview route, which is sub-project B/F material.
- The GitHub "require approval for all outside collaborators" setting — the API answers `Fork PR approval is not allowed for private repositories` on all four repos (measured 2026-10-12). It goes on the going-public checklist in the audit; the workflow-level guard (Task 7) is what this PR can do.
- Runner network isolation — infrastructure on the Unraid box, not a repo change.
- The OVH deploy itself — happens after merge, from `main`, by the operator (§Close-out).

**Scope of what this branch touches (batch by file when executing):**

| batch | files |
|---|---|
| 1. deploy config | `config/deploy.yml`, `config/deploy.ovh.yml`, `config/deploy.share.yml`, `config/deploy.s3.yml`, `.kamal/secrets.ovh`, `test/deploy_hygiene_test.rb`, `docs/DEPLOY.md`, `script/maker_smoke.py` |
| 2. device login throttle | `app/controllers/v1/devices_controller.rb`, `test/integration/v1/device_login_throttle_test.rb` (new) |
| 3. public surface throttle | `app/controllers/public/base_controller.rb`, `test/integration/web/public_throttle_test.rb` (new) |
| 4. log hygiene | `config/initializers/filter_parameter_logging.rb`, `app/controllers/csp_reports_controller.rb`, `test/lib/parameter_filter_test.rb` (new), `test/integration/csp_report_test.rb` |
| 5. fork-PR guard | `.github/workflows/ci.yml`, `test/ci_hygiene_test.rb` |
| 6. record + audit | `docs/AUDIT-2026-10-12-readiness.md` (commit it; add the going-public checklist), `bin/log` writes |

Batches 2–5 are disjoint from each other and from 1; they may run in parallel. Batch 1 is one implementer.

---

### Task 1: The OVH overlay routes its own public names with the Cloudflare origin certificate

**Why:** `config/deploy.ovh.yml` declares no `proxy:` block, so it inherits the base's `hosts: [chunk.tinkerex.local, chunk.tinkerex.home]`. Kamal replaces ARRAYS on merge, so an overlay `hosts:` list wins outright. Cloudflare sits in front (Full strict), intercepts ACME, and completes TLS to the origin only if kamal-proxy serves a certificate for the SNI — the origin cert in `op://tinkerex/tinkerex-origin` (SANs `tinkerex.com`, `*.tinkerex.com`, valid to 2041; fields `certificate` and `private key`, measured 2026-10-12). `www.tinkerex.com` answers 525 today because the proxy has no cert for it.

**Files:**
- Modify: `config/deploy.ovh.yml` (add a top-level `proxy:` block beside `servers:`)
- Modify: `.kamal/secrets.ovh` (two new reference lines)
- Modify: `test/deploy_hygiene_test.rb` (new test after "no two Unraid destinations claim the same hostname"; fix the stale comment at lines 16–22 that says OVH inherits on purpose)

- [ ] **Step 1: Write the failing test**

Add to `test/deploy_hygiene_test.rb`, after the "no two Unraid destinations claim the same hostname" test:

```ruby
  # The one internet-facing destination. Cloudflare (orange cloud, Full strict) terminates the
  # visitor's TLS and opens a SECOND TLS connection to the origin, which succeeds only if
  # kamal-proxy serves a certificate for that SNI — and Cloudflare intercepts the HTTP-01
  # challenge, so kamal-proxy's own ACME can never mint one. The Cloudflare ORIGIN certificate
  # (op://tinkerex/tinkerex-origin) is the only cert that works there, and it reaches the proxy
  # through `proxy.ssl.certificate_pem` / `private_key_pem`, which name SECRETS (resolved from
  # .kamal/secrets.ovh — the secrets test below requires both to be defined there).
  PUBLIC_HOSTS = %w[tinkerex.com www.tinkerex.com].freeze

  test "the internet-facing destination routes its public names with a custom certificate, never a LAN name" do
    # Until 2026-10-12 the OVH overlay declared no `proxy:` block and INHERITED the base's
    # chunk.tinkerex.{local,home} — kamal-proxy then routed only those names, so www.tinkerex.com
    # answered 525 at Cloudflare's edge and a redeploy would have taken the apex down too.
    # (docs/AUDIT-2026-10-12-readiness.md §0.)
    require "kamal"
    ovh = Kamal::Configuration.create_from(
      config_file: ROOT.join("config/deploy.yml"), destination: "ovh"
    ).proxy
    assert_equal PUBLIC_HOSTS.sort, ovh.hosts.sort,
                 "deploy.ovh.yml must carry its own `proxy: hosts:` list (kamal REPLACES arrays " \
                 "on merge, so an overlay list wins; without one it inherits the LAN names)"
    assert ovh.ssl?, "the public host must terminate TLS at kamal-proxy (Cloudflare Full strict)"
    assert ovh.custom_ssl_certificate?,
           "Cloudflare intercepts ACME, so `ssl: true` alone never gets a certificate — name the " \
           "origin cert and key via ssl.certificate_pem / ssl.private_key_pem"

    lan = UNRAID_DESTINATIONS.keys.flat_map { |destination| proxy_hosts(destination) }
    assert_empty ovh.hosts & lan, "an internet-facing destination must not route a LAN-only name"
  end
```

Also replace the stale comment block at lines 16–22 (the sentence beginning "OVH is absent on purpose: it sets no `proxy` block, so it INHERITS the base's") with:

```ruby
  # joined chunk/share — same host, own container, own proxy hostnames. OVH is absent here because
  # it is not an Unraid destination: it carries its OWN `proxy:` block (public names + the origin
  # certificate), pinned by "the internet-facing destination routes its public names" below.
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/deploy_hygiene_test.rb -n /internet-facing/`
Expected: FAIL — `assert_equal` reports hosts `["chunk.tinkerex.home", "chunk.tinkerex.local"]`.

- [ ] **Step 3: Add the proxy block and the two secret references**

In `config/deploy.ovh.yml`, directly after the `ssh:` block (line ~29), add:

```yaml
# THE PUBLIC NAMES AND THE ORIGIN CERTIFICATE. Kamal REPLACES arrays on merge, so this `hosts:`
# list wins over the base's chunk.tinkerex.{local,home} outright — without this block the overlay
# INHERITED those LAN names and kamal-proxy answered 404 for tinkerex.com (measured 2026-10-12:
# www.tinkerex.com was a 525 at Cloudflare's edge for exactly this reason). Cloudflare proxies the
# apex and www (orange cloud, Full strict) and opens its own TLS connection to this box, which
# succeeds only if kamal-proxy serves a certificate for the SNI; Cloudflare also intercepts the
# HTTP-01 challenge, so `ssl: true` alone can never obtain one. The Cloudflare ORIGIN certificate
# (op://tinkerex/tinkerex-origin, SANs tinkerex.com + *.tinkerex.com, valid to 2041) is the one
# that works, and it reaches the proxy as two SECRETS resolved from .kamal/secrets.ovh —
# test/deploy_hygiene_test.rb requires both to be defined there. Design and the Cloudflare-side
# steps: docs/superpowers/specs/2026-07-26-ovh-tinkerex-domain-tls-design.md.
proxy:
  hosts:
    - tinkerex.com
    - www.tinkerex.com
  ssl:
    certificate_pem: OVH_ORIGIN_CERTIFICATE_PEM
    private_key_pem: OVH_ORIGIN_PRIVATE_KEY_PEM
```

In `.kamal/secrets.ovh`, append:

```sh
# THE CLOUDFLARE ORIGIN CERTIFICATE FOR kamal-proxy (config/deploy.ovh.yml `proxy: ssl:`). Both
# values are multi-line PEMs: bin/secret prints them verbatim (`printf '%s'`) and Kamal's
# InlineCommandSubstitution keeps everything but the trailing newline, so they survive the
# dotenv parse intact. Not in secrets-common: no other destination terminates TLS.
OVH_ORIGIN_CERTIFICATE_PEM=$(bin/secret OVH_ORIGIN_CERTIFICATE_PEM 'op://tinkerex/tinkerex-origin/certificate')
OVH_ORIGIN_PRIVATE_KEY_PEM=$(bin/secret OVH_ORIGIN_PRIVATE_KEY_PEM 'op://tinkerex/tinkerex-origin/private key')
```

- [ ] **Step 4: Run the whole hygiene file to verify it passes**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/deploy_hygiene_test.rb`
Expected: PASS, including "every secret a destination declares is defined in a file that destination actually reads".

- [ ] **Step 5: Mutation-check**

Remove the `OVH_ORIGIN_PRIVATE_KEY_PEM=` line from `.kamal/secrets.ovh`, rerun the file: the secrets test must go RED naming `OVH_ORIGIN_PRIVATE_KEY_PEM`. Restore the file from git. Then delete the `hosts:` list from the overlay, rerun: the new test must go RED on the inherited LAN names. Restore from git and re-apply Step 3. Report both outputs.

- [ ] **Step 6: Commit** — `git add config/deploy.ovh.yml .kamal/secrets.ovh test/deploy_hygiene_test.rb`, message "The OVH overlay routes tinkerex.com and www with the Cloudflare origin certificate" plus the two-sentence body (the overlay inherited the LAN names; pinned by the hygiene test, which also requires both PEM secrets).

---

### Task 2: Every destination names the host its mail links are built from

**Why:** `config/environments/production.rb:116-119` builds confirmation and reset links from `APP_HOST` and falls back to `APP_HOST-IS-NOT-SET.invalid`; no `config/deploy*.yml` sets it (measured), so every link any deployment ever sent pointed nowhere.

**Files:**
- Modify: `config/deploy.yml` (env.clear), `config/deploy.share.yml`, `config/deploy.s3.yml`, `config/deploy.ovh.yml`
- Modify: `test/deploy_hygiene_test.rb`

- [ ] **Step 1: Write the failing test**

Add after Task 1's test:

```ruby
  test "every destination names the host its mail links are built from, and kamal-proxy routes that name" do
    # config/environments/production.rb builds confirmation and reset links from APP_HOST and
    # falls back to a loud `.invalid` placeholder. Until 2026-10-12 NO destination set it, so the
    # one link a new maker must click pointed nowhere on every box. Read off the MERGED config so
    # an overlay that forgets it inherits the base's answer rather than passing on a nil — and
    # require the name to be one the destination's proxy actually routes, so a link that is
    # emitted can be followed.
    require "kamal"
    LIBRARY_DESTINATIONS.each do |destination|
      config = Kamal::Configuration.create_from(
        config_file: ROOT.join("config/deploy.yml"), destination: destination
      )
      host = at(config.raw_config, "env", "clear").to_h["APP_HOST"].to_s
      assert host.present?, "#{destination || 'base'}: env.clear must set APP_HOST"
      assert_includes config.proxy.hosts, host,
                      "#{destination || 'base'}: APP_HOST=#{host} is not a name kamal-proxy routes " \
                      "for that destination (#{config.proxy.hosts.inspect}) — a mail link to it 404s"
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/deploy_hygiene_test.rb -n /mail\ links/`
Expected: FAIL — "base: env.clear must set APP_HOST".

- [ ] **Step 3: Set APP_HOST on all four destinations**

`config/deploy.yml`, in `env: clear:` after `RAILS_MAX_THREADS: 16`:

```yaml
    # THE HOST MAIL LINKS ARE BUILT FROM (config/environments/production.rb). Confirmation and
    # password-reset links carry this name; the fallback there is a loud `.invalid`, and until
    # 2026-10-12 every destination shipped that fallback because none set this. Each overlay sets
    # its own, and test/deploy_hygiene_test.rb requires the name to be one kamal-proxy routes for
    # that destination. `.home` rather than `.local`: it resolves from every client on the LAN and
    # the tailnet (*.tinkerex.home is a wildcard to the NPM front proxy), `.local` only where an
    # /etc/hosts line was added by hand.
    APP_HOST: chunk.tinkerex.home
```

`config/deploy.share.yml` env.clear: `APP_HOST: share.tinkerex.home`
`config/deploy.s3.yml` env.clear: `APP_HOST: s3.tinkerex.home`
`config/deploy.ovh.yml` env.clear, beside `FORCE_SSL: "1"`: `APP_HOST: tinkerex.com` with the comment `# Mail links: https://tinkerex.com/… (FORCE_SSL picks the scheme; production.rb).`

- [ ] **Step 4: Run to verify it passes**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/deploy_hygiene_test.rb`
Expected: PASS.

- [ ] **Step 5: Mutation-check**

Change the s3 overlay's value to `s3.tinkerex.example`, rerun: RED naming s3. Restore. Report the output.

- [ ] **Step 6: Commit** — the four deploy files + the test; message "Every destination sets APP_HOST, the name its confirmation and reset links carry".

---

### Task 3: No committed destination opens the test-signup seam

**Why:** `config/deploy.yml:119` sets `ENABLE_TEST_SIGNUP: true` in the BASE, so every overlay inherits an unthrottled endpoint that mints confirmed accounts and answers `user_id` for any existing address with no password. PR #388 blanked it for OVH only. The seam stays available for a deliberate, temporary opt-in (`kamal env push` with the flag, or a local `bin/rails server`), never in a committed destination.

**Files:**
- Modify: `config/deploy.yml` (remove the line and rewrite its comment), `config/deploy.ovh.yml` (remove the now-redundant blank and shorten its comment)
- Modify: `test/deploy_hygiene_test.rb` (widen the existing test to every destination)
- Modify: `docs/DEPLOY.md` ("Create one" snippet), `script/maker_smoke.py` docstring if it claims the box has the seam open

- [ ] **Step 1: Widen the test**

Replace the body of "no destination outside the LAN opens the unverified test-signup seam" with a test named "no committed destination opens the unverified test-signup seam":

```ruby
  test "no committed destination opens the unverified test-signup seam" do
    # POST /v1/test/users mints CONFIRMED accounts with no email check (V1::TestUsersController),
    # answers `user_id` for an existing address with no password, and has no throttle. On a
    # share/s3 deployment every account is indexed the SAME library, so an open seam hands a
    # stranger read/write/delete on the owner's files. deploy.yml set it for the LAN-only Unraid
    # box for a year, kamal DEEP-MERGES env.clear, and the one internet-facing overlay inherited it
    # for two months. Since 2026-10-12 NO committed destination sets it: the seam is a deliberate,
    # temporary opt-in for a harness run (`kamal env push` after exporting it, or a local
    # `ENABLE_TEST_SIGNUP=1 bin/rails server`), never a standing property of a box.
    #
    # Read off the MERGED config (deep-merge reflected, not re-implemented), and `.to_s.blank?`
    # rather than `.blank?`: the gate is ENV.present?, and kamal renders a YAML `false` as the
    # string "false", which is present — so `false` would read closed here and run open.
    require "kamal"
    LIBRARY_DESTINATIONS.each do |destination|
      clear = at(Kamal::Configuration.create_from(
        config_file: ROOT.join("config/deploy.yml"), destination: destination
      ).raw_config, "env", "clear").to_h
      # Non-vacuity: an absent key is CLOSED (nil.to_s is blank), so a raw_config shape change that
      # made every lookup nil would pass the real assertion over nothing.
      assert clear.key?("LIBRARY_BACKEND"),
             "#{destination || 'base'}: merged env.clear has no LIBRARY_BACKEND -- raw_config shape changed?"
      assert clear["ENABLE_TEST_SIGNUP"].to_s.blank?,
             "#{destination || 'base'} resolves ENABLE_TEST_SIGNUP=#{clear['ENABLE_TEST_SIGNUP'].inspect}: " \
             "the unverified POST /v1/test/users signup would be open to anyone who can reach that host"
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/deploy_hygiene_test.rb -n /test-signup/`
Expected: FAIL — "base resolves ENABLE_TEST_SIGNUP=true".

- [ ] **Step 3: Remove the flag from the base and the blank from the overlay**

`config/deploy.yml`: delete `ENABLE_TEST_SIGNUP: true` and replace its five-line comment with:

```yaml
    # THE TEST-SIGNUP SEAM IS NOT SET HERE, OR IN ANY DESTINATION (2026-10-12). POST /v1/test/users
    # mints confirmed accounts with no email check and no throttle, and env.clear deep-merges into
    # every overlay — the internet-facing OVH box inherited it for two months. A harness run that
    # needs it exports ENABLE_TEST_SIGNUP=1 for that run only (`kamal env push`, or a local
    # `bin/rails server`); test/deploy_hygiene_test.rb refuses any committed destination that sets it.
```

`config/deploy.ovh.yml`: delete the `ENABLE_TEST_SIGNUP: ""` line and its comment block (lines ~165–186); in their place one comment: `# ENABLE_TEST_SIGNUP: not set anywhere since 2026-10-12 — see deploy.yml and test/deploy_hygiene_test.rb.`

- [ ] **Step 4: Run the file, then the seam's own tests**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/deploy_hygiene_test.rb test/integration/v1/test_users_seam_test.rb`
Expected: PASS (the controller and its non-production route are untouched).

- [ ] **Step 5: Mutation-check**

Put `ENABLE_TEST_SIGNUP: true` back into `config/deploy.share.yml`'s env.clear, rerun: RED naming share. Restore. Report the output.

- [ ] **Step 6: Sweep the docs that describe the seam as open**

`docs/DEPLOY.md`: in the test-accounts section, replace the paragraph "Create one (the seam is open on all three; …)" and its curl snippet with a console creation recipe (the same `ssh … docker exec -i -e DEMO_PASSWORD … bin/rails runner -` shape as the reset below it, running `User.create!(email: "demo@tinkerex.local", password: ENV.fetch("DEMO_PASSWORD"), confirmed_at: Time.current)` and aborting if the address exists), followed by one paragraph: a harness that genuinely needs the HTTP seam exports `ENABLE_TEST_SIGNUP=1` for that run only (`kamal env push -d <dest>` then `kamal app boot -d <dest>`; blank it the same way afterwards), never committed to a destination.

`script/maker_smoke.py`: if its docstring says the Unraid box serves the seam, change that sentence to say the seam must be exported for the run (`ENABLE_TEST_SIGNUP=1`) and is closed on every committed destination. Grep: `grep -n "ENABLE_TEST_SIGNUP\|test/users" script/maker_smoke.py`.

- [ ] **Step 7: Commit** — message "No committed destination opens the test-signup seam".

---

### Task 4: `POST /v1/devices/login` is throttled per IP

**Why:** `app/controllers/v1/devices_controller.rb:13-41` has no `rate_limit`; Devise lockable (10 misses → 1 h lock, `config/initializers/devise.rb:239-242`) bounds one ACCOUNT and the lock also blocks web sign-in, so the API door is both a credential-stuffing surface and a lockout weapon. The web login already carries exactly this throttle (`app/controllers/users/sessions_controller.rb:13-17`).

**Files:**
- Modify: `app/controllers/v1/devices_controller.rb`
- Create: `test/integration/v1/device_login_throttle_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module V1
  # Per-IP throttle on the one v1 endpoint that takes HUMAN credentials. Lockable (10 misses, one
  # hour) bounds guesses at ONE account; this bounds one guess each at ten thousand accounts, and
  # it stops anyone who knows an address from locking that account over and over — the lock also
  # blocks web sign-in. Mirrors users/sessions_controller.rb's numbers so the two doors agree.
  #
  # THE COUNTER LIVES IN config.action_controller.cache_store AND IS SHARED ACROSS TESTS (every
  # integration request comes from 127.0.0.1), so setup clears it.
  class DeviceLoginThrottleTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      ActionController::Base.cache_store.clear
      @target  = User.create!(email: "api-target@example.com",  password: PASSWORD, confirmed_at: Time.current)
      @another = User.create!(email: "api-another@example.com", password: PASSWORD, confirmed_at: Time.current)
    end

    def login(email, password)
      post "/v1/devices/login", params: { email:, password:, device_name: "laptop" }, as: :json
      response
    end

    test "attempts past the per-IP limit are refused with 429, not 401" do
      10.times do
        login(@target.email, "wrong")
        assert_response :unauthorized, "attempts under the limit get the normal answer"
      end
      login(@target.email, "wrong")
      assert_response :too_many_requests
      assert_equal "too_many_attempts", JSON.parse(response.body)["error"]
    end

    test "a throttled IP cannot enrol even with the CORRECT password of an UNLOCKED account" do
      # Gates the ACTION, not just failures: the correct guess on attempt 12 must not be let
      # through. A second account, so lockable's own 401 on the first cannot stand in for the
      # throttle's 429 — without the throttle this request would mint a device and answer 201.
      11.times { login(@target.email, "wrong") }
      assert_no_difference -> { Device.count } do
        login(@another.email, PASSWORD)
        assert_response :too_many_requests
      end
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/integration/v1/device_login_throttle_test.rb`
Expected: FAIL — 11th attempt is 401, and the second test gets 201.

- [ ] **Step 3: Add the throttle**

In `app/controllers/v1/devices_controller.rb`, directly after `skip_before_action :authenticate_device!, only: :login`:

```ruby
    # PER-IP, ON TOP OF Devise :lockable, which is per-ACCOUNT — the same numbers as the web
    # login (users/sessions_controller.rb) so the two human-credential doors agree. Lockable stops
    # 10 guesses at one address; this stops one guess each at ten thousand addresses, and it stops
    # an attacker from locking a known account over and over (the lock also blocks web sign-in).
    # It gates the ACTION, not just failures: a correct guess on attempt 11 is still refused.
    # Counts in config.action_controller.cache_store (Solid Cache in production). Pinned by
    # test/integration/v1/device_login_throttle_test.rb.
    rate_limit to: 10, within: 3.minutes, only: :login,
               with: -> { render json: { error: "too_many_attempts" }, status: :too_many_requests }
```

- [ ] **Step 4: Run to verify it passes, with the existing login suite**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/integration/v1/device_login_throttle_test.rb test/integration/v1/device_login_test.rb`
Expected: PASS.

- [ ] **Step 5: Mutation-check**

Comment out the `rate_limit` lines, rerun the new file: both tests RED (401 / 201). Restore. Report the output.

- [ ] **Step 6: Commit** — message "Device login is throttled per IP, the same numbers as the web login".

---

### Task 5: The anonymous public surface has a per-IP budget

**Why:** `app/controllers/public/*` carry no `rate_limit`; a page render enqueues up to 100 thumbnail jobs and `#view` enqueues geometry, and on share the byte route streams any size through Puma. Bounded per content already, but a crawler pays nothing per request. 600 requests a minute is far above a human (a 60-cover page is 61 requests) and far below a scraper.

**Files:**
- Modify: `app/controllers/public/base_controller.rb`
- Create: `test/integration/web/public_throttle_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

module Web
  # One per-IP budget over the whole anonymous surface (Public::BaseController). Every public
  # page is unauthenticated and does real work — a cover page enqueues renders, the byte route
  # streams a file through Puma on share — so a visitor who pays nothing per request can make the
  # box pay for all of them. The budget is far above a person (a page of sixty covers is 61
  # requests) and far below a scraper.
  #
  # THE COUNTER IS SHARED ACROSS TESTS (every request is 127.0.0.1); setup clears it.
  class PublicThrottleTest < ActionDispatch::IntegrationTest
    setup { ActionController::Base.cache_store.clear }

    test "an anonymous visitor past the per-minute budget is refused, not served" do
      budget = Public::BaseController::ANONYMOUS_REQUESTS_PER_MINUTE
      budget.times do
        get public_explore_path
        assert_response :success
      end
      get public_explore_path
      assert_response :too_many_requests
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/integration/web/public_throttle_test.rb`
Expected: FAIL — `NameError: uninitialized constant Public::BaseController::ANONYMOUS_REQUESTS_PER_MINUTE`.

- [ ] **Step 3: Add the budget**

In `app/controllers/public/base_controller.rb`, after `helper_method :public_surface?`:

```ruby
    # ONE PER-IP BUDGET OVER THE WHOLE ANONYMOUS SURFACE. Every action here is unauthenticated and
    # does real work — a cover page enqueues up to ThumbnailMap's render cap, `files#view` enqueues
    # geometry, and on share the byte route streams the file through Puma — bounded per content
    # but free per request to the visitor. Far above a person (a page of sixty covers is 61
    # requests) and far below a scraper. Counts in config.action_controller.cache_store (Solid
    # Cache in production); pinned by test/integration/web/public_throttle_test.rb.
    ANONYMOUS_REQUESTS_PER_MINUTE = 600
    rate_limit to: ANONYMOUS_REQUESTS_PER_MINUTE, within: 1.minute,
               with: -> { head :too_many_requests }
```

- [ ] **Step 4: Run to verify it passes, plus the public suites**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/integration/web/public_throttle_test.rb test/integration/web/public_explore_test.rb test/integration/web/public_user_page_test.rb test/integration/web/public_file_test.rb`
Expected: PASS.

- [ ] **Step 5: Mutation-check**

Comment out the `rate_limit` lines (keep the constant), rerun: RED (the 601st request is 200). Restore. Report the output.

- [ ] **Step 6: Commit** — message "The anonymous public surface has a per-IP budget".

---

### Task 6: The unlisted-project token stays out of the logs

**Why:** `config/initializers/filter_parameter_logging.rb` filters `token` but not `k`, so every request to an unlisted page logs its 128-bit credential; the CSP collector logs `document-uri` with its query string, which carries the same token for a same-origin page. A bare `:k` entry would be WRONG — Rails matches filter names as substrings (`:passw` matches `password`), so `:k` would redact `kind`, `block`, every key with a k. An anchored Regexp is the right spelling.

**Files:**
- Modify: `config/initializers/filter_parameter_logging.rb`
- Modify: `app/controllers/csp_reports_controller.rb` (`summary`)
- Create: `test/lib/parameter_filter_test.rb`
- Modify: `test/integration/csp_report_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/lib/parameter_filter_test.rb`:

```ruby
require "test_helper"

# The unlisted-project token travels as `?k=<128-bit token>` on every request to an unlisted page
# (Public::BaseController#unlisted_token_ok?). Rails logs request parameters, so the credential
# was written to the log on every visit until it joined filter_parameters.
#
# WHY A REGEXP AND NOT `:k`: ActiveSupport::ParameterFilter matches a String/Symbol entry as a
# SUBSTRING of the key (that is how `:passw` catches `password`), so a bare `:k` would redact
# `kind`, `block_id`, `node_ids`, every key containing a k. The second assertion pins that.
class ParameterFilterTest < ActiveSupport::TestCase
  def filtered(params)
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(params)
  end

  test "the unlisted token is filtered" do
    assert_equal "[FILTERED]", filtered({ "k" => "0123456789abcdef" })["k"]
  end

  test "keys that merely contain a k are not" do
    out = filtered({ "kind" => "thumbnail", "block_id" => "7", "node_ids" => "a,b" })
    assert_equal({ "kind" => "thumbnail", "block_id" => "7", "node_ids" => "a,b" }, out)
  end
end
```

In `test/integration/csp_report_test.rb`, after the "only the allowlisted fields are logged" test:

```ruby
  test "a URL field's query string is not logged — it can carry the unlisted-project token" do
    logged = capture_csp_logs do
      post REPORT_PATH,
           params: { "csp-report" => { "violated-directive" => "img-src",
                                       "document-uri" => "https://x.test/u/ada/rig?k=SECRETTOKEN",
                                       "blocked-uri"  => "https://y.test/img.png?sig=SECRETSIG" } }.to_json,
           headers: { "CONTENT_TYPE" => "application/csp-report" }
    end

    line = logged.sole
    assert_includes line, "/u/ada/rig", "the path is still logged"
    assert_not_includes line, "SECRETTOKEN"
    assert_not_includes line, "SECRETSIG"
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/lib/parameter_filter_test.rb test/integration/csp_report_test.rb`
Expected: FAIL — `"0123456789abcdef"` not filtered; the CSP line contains SECRETTOKEN.

- [ ] **Step 3: Implement**

`config/initializers/filter_parameter_logging.rb` — append to the list:

```ruby
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # The unlisted-project credential, `?k=<token>` (Public::BaseController). ANCHORED: a String
  # entry matches as a substring, so a bare `:k` would redact every key containing a k
  # (test/lib/parameter_filter_test.rb pins both halves).
  /\Ak\z/
]
```

`app/controllers/csp_reports_controller.rb` — in `summary`, before the `out[field] = …` line:

```ruby
      value = value.split("?", 2).first if URL_FIELDS.include?(field) && value.is_a?(String)
```

and beside `FIELDS`:

```ruby
  # The three URL-valued fields. A same-origin document-uri carries the page's query string, which
  # for an unlisted project IS the credential (`?k=`); a blocked-uri can carry a signed URL. The
  # path is what a violation needs; the query is dropped before anything is written.
  URL_FIELDS = %w[document-uri blocked-uri source-file].freeze
```

- [ ] **Step 4: Run to verify they pass**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/lib/parameter_filter_test.rb test/integration/csp_report_test.rb`
Expected: PASS.

- [ ] **Step 5: Mutation-check**

(a) Replace `/\Ak\z/` with `:k`: the "keys that merely contain a k" test must go RED. (b) Remove the `split("?", 2)` line: the CSP test must go RED on SECRETTOKEN. Restore both. Report the outputs.

- [ ] **Step 6: Commit** — message "The unlisted-project token stays out of the request log and the CSP log".

---

### Task 7: CI refuses to run for a pull request from a fork

**Why:** `.github/workflows/ci.yml` runs on `pull_request` on self-hosted LAN runners with `SYS_PTRACE` and `seccomp:unconfined` (`ops/ci-runner-stack.yml:131-134`). Private today, so no fork can exist; the day a repo goes public, a fork's PR would execute its branch on the LAN. The GitHub-side approval setting cannot be set on a private repo (measured), so the workflow carries the guard itself and the setting goes on the going-public checklist.

**Files:**
- Modify: `.github/workflows/ci.yml` (every job)
- Modify: `test/ci_hygiene_test.rb`

- [ ] **Step 1: Write the failing test**

Add to `test/ci_hygiene_test.rb`, after "ci.yml's gate jobs are exactly the gates bin/ci says CI must run":

```ruby
  # The expression every job must carry. `github.repository` is "owner/name" of THIS repo and
  # `head.repo.full_name` is where the PR's branch lives; they differ exactly for a fork.
  FORK_GUARD = "github.event.pull_request.head.repo.full_name == github.repository".freeze

  test "every ci.yml job refuses a pull request from a fork" do
    # The runners are self-hosted containers on the LAN with SYS_PTRACE and seccomp unconfined
    # (ops/ci-runner-stack.yml), and `bin/ci` runs the branch's own code. A fork's pull request is
    # therefore code execution on the LAN by whoever opened it. GitHub's "require approval for all
    # outside collaborators" setting is the other half and CANNOT be set while the repo is private
    # (the API refuses: "Fork PR approval is not allowed for private repositories", 2026-10-12) —
    # so the workflow carries the guard itself, on EVERY job: a guard on preflight alone would not
    # stop the gate jobs, which do not `needs:` it (ci_hygiene_test's preflight exemption).
    jobs = ci_yml_jobs
    assert jobs.any?, "expected ci.yml to declare jobs"
    jobs.each do |name, job|
      assert_includes job["if"].to_s, FORK_GUARD,
                      "ci.yml job `#{name}` must carry `if: ${{ #{FORK_GUARD} }}` (a fork's PR " \
                      "runs its own code on the LAN runners otherwise)"
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/ci_hygiene_test.rb -n /fork/`
Expected: FAIL naming `preflight`.

- [ ] **Step 3: Add the guard to every job**

Under each of the seven jobs, directly after `runs-on: [self-hosted, linux]`, add the identical line:

```yaml
    if: ${{ github.event.pull_request.head.repo.full_name == github.repository }}  # never a fork — see the note above preflight
```

Above the `preflight:` job, add one comment:

```yaml
  # EVERY JOB BELOW CARRIES `if: head.repo.full_name == github.repository`. The runners are
  # self-hosted containers on the LAN (ops/ci-runner-stack.yml: SYS_PTRACE, seccomp unconfined)
  # and bin/ci runs the branch's own code, so a pull request from a FORK is code execution on
  # the LAN by whoever opened it. Harmless while the repo is private (no fork can exist) and the
  # thing that matters the day it is public. GitHub's own "require approval for all outside
  # collaborators" setting is the other half; it cannot be set on a private repo, so flipping the
  # repo public and setting it are ONE step (docs/AUDIT-2026-10-12-readiness.md, the going-public
  # checklist). Pinned on every job by test/ci_hygiene_test.rb.
```

- [ ] **Step 4: Run the whole hygiene file**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/ci_hygiene_test.rb`
Expected: PASS (the preflight-gating test's linux exemption is unaffected by an unrelated `if`).

- [ ] **Step 5: Mutation-check**

Delete the `if:` line from the `lint` job, rerun: RED naming `lint`. Restore. Report the output.

- [ ] **Step 6: Commit** — message "CI refuses a pull request from a fork on every job".

---

### Task 8: Commit the audit with a going-public checklist, and file the record

**Files:**
- Modify: `docs/AUDIT-2026-10-12-readiness.md` (append §6 "Before a repo goes public"; mark §0's OVH overlay row and §1 items 4, 5, 7, 8, 10 as fixed by this PR)
- `bin/log` writes (operator, not git)

- [ ] **Step 1: Append to the audit**

```markdown
## 6. Before a repo goes public — the steps that are impossible while it is private

1. **Actions → "Require approval for all outside collaborators"** on each repo, in the same
   sitting as the visibility flip: `gh api -X PUT repos/chaim354/<repo>/actions/permissions/fork-pr-contributor-approval -f approval_policy=all_external_contributors`.
   The API refuses this on a private repo (measured 2026-10-12), which is why the workflow carries
   its own fork guard (`.github/workflows/ci.yml`, pinned by `test/ci_hygiene_test.rb`).
2. **Branch protection on `main`** (required checks = the seven `ci.yml` jobs; no force-push) — also
   unavailable on the free plan while private.
3. **ghcr package visibility** is set per package and does NOT follow the repo (`config/deploy.yml:64-73`).
   Decide which images a stranger may pull and flip them deliberately.
4. **Rotate anything that was ever a literal in history** — the demo password (`git log -S'MakerDemo2026'`)
   is rotated per §1.12; grep the history, not the tree.
5. **Runner isolation**: the Unraid runner containers reach the LAN; put them on their own network
   before the first outside PR is approved.
```

And at the top of §1, one line: `**Fixed in PR <n> (2026-10-12):** items 4, 5, 7, 8, 10 and the §0 OVH proxy row. The rest stand.` (fill `<n>` at PR time).

- [ ] **Step 2: Commit the audit and this plan** — message "The readiness audit and sub-project A's plan".

- [ ] **Step 3: Record hygiene (operator steps, after the branch is green)**

```sh
bin/log close 278 279 283          # fixed by arc #292 (hardening); verified in code 2026-10-12
bin/log note 126 "Largely stale on 2026-10-12: inventory items, BOM, suppliers/locations and tags have web UI; only Maker::Collection/CollectionItem and Maker::Item (the desktop catalog) have none. Left open for those."
bin/log note 134 "Config fixed in PR #388 and widened in this PR (no destination sets the flag). The live OVH box still runs a pre-September image; close at the next -d ovh deploy."
bin/log arc --from-pr 388          # the pre-publication fixes arc was never filed
```

---

### Task 9: Rotate the demo accounts (operator step, no git)

**Why:** PR #388 moved the password out of the tree but it stays in history (`d1057f07 e504d412 8bbe3352 da9d4232`); `docs/DEPLOY.md` says to reset all accounts to the new 1Password value. Measured 2026-10-12: the account exists on share and s3 (both id 1, confirmed, 0 devices) and is absent on the chunk_remote base.

- [ ] **Step 1: Create the 1Password item with a generated password (the value is never printed)**

```sh
op item create --vault tinkerex --category login --title "unraid demo account" \
  --url http://share.tinkerex.home --generate-password=24,letters,digits,symbols \
  username=demo@tinkerex.local >/dev/null && echo created
op read --no-newline 'op://tinkerex/unraid demo account/password' | wc -c   # length only
```

- [ ] **Step 2: Reset share and s3 with the documented recipe (docs/DEPLOY.md, "Reset a forgotten one")**

Run it once with `name=^tinkerex-web-share-` and once with `name=^tinkerex-web-s3-`. Expected output each: `demo@tinkerex.local updated`.

- [ ] **Step 3: Verify the old value is dead** — sign-in with the old password is a 401 at `POST /v1/devices/login` on share (do not print the new one); record "rotated 2026-10-12" as a note on the #388 arc.

---

## Close-out

1. `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci` from the worktree; read the three legs' run counts (identical, ±2 assertions is the known flap).
2. `/finish-branch` → PR, then `bin/log arc --from-pr <n>`.
3. **After merge, the OVH deploy** (operator; needs the OVHcloud ssh key unlocked in the 1Password agent, which this session could not reach):
   ```sh
   git checkout main && git pull --ff-only
   bin/secrets-preflight ovh                  # must list OVH_ORIGIN_CERTIFICATE_PEM / _PRIVATE_KEY_PEM as ok
   bin/kamal config -d ovh | grep -A6 proxy   # hosts tinkerex.com + www, tls true, cert path set
   bin/kamal deploy -d ovh
   curl -sI https://tinkerex.com/up | head -1          # 200
   curl -sI https://www.tinkerex.com/up | head -1      # 200, no longer 525
   curl -s -o /dev/null -w '%{http_code}\n' -X POST https://tinkerex.com/v1/test/users -H 'Content-Type: application/json' -d '{"email":"x@example.com","password":"x"}'   # 404
   curl -sI https://tinkerex.com/explore | head -1     # 200 — the image is current
   bin/log deploy --image <sha>; bin/log close 134
   ```
   If kamal-proxy on the box refuses the custom cert on first boot (a `proxy:` block added to an already-running service), `bin/kamal proxy reboot -d ovh` once, then re-run the probes.
