# B — Accounts that work: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repo `.claude/commands/execute-plan.md` governs batching: Tasks 1, 2 and 3 touch disjoint files and run in parallel, each in its own worktree; Task 4 is the orchestrator's.

**Goal:** A stranger who installs the app gets an owner account without a mail server, an operator can keep strangers out (and cannot accidentally let them into a single-library backend), mail is configured by environment, and the per-IP throttles work behind Cloudflare.

**Architecture:** Three small pure modules under `lib/tinkerex/` (`MailSettings`, `Registration`) and one pinned data file (`config/cloudflare_ips.yml`), wired by `after_initialize` initializers that mirror `config/initializers/library_backend_check.rb`; Devise is hooked at exactly two points (`build_resource`, a `before_action`). Every rule is pinned by a test that drives the real request or the real middleware, and mutation-checked. Design: `docs/superpowers/specs/2026-10-13-b-accounts-that-work-design.md`.

**Tech Stack:** Rails 8.1, Devise 5, `ActionDispatch::RemoteIp`, Minitest. Run tests with `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test <files>`.

**Conventions that bind every task:**
- Tests under `test/lib/` are `ActiveSupport::TestCase`; integration tests under `test/integration/web/` are `ActionDispatch::IntegrationTest` and get the per-test rate-limit clear from `test_helper.rb`.
- Stub ENV the way `test/integration/v1/test_users_seam_test.rb` does: set `ENV["X"]` in `setup`, delete it in `teardown`. There is no `with_env` helper and no `Object#stub` (Minitest 6); the house has a `#replacing` helper for methods.
- A lib file an initializer needs at top level is `require`d by name (`require "library_backend_check"` is the precedent); a lib constant used from a controller, view or an `after_initialize` block is autoloaded (`config.autoload_lib`).
- Commit per task with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`; no backticks or `!` in commit messages (zsh); subjects state the effect.
- Mutation-check every guard: break it, run the named test, report the actual output, restore with `git checkout -- <file>`, and `rm -rf tmp/cache/bootsnap*` after restoring a Ruby file.

---

### Task 1: Cloudflare's ranges are trusted proxies, so `remote_ip` is the visitor behind Cloudflare

**Files:**
- Create: `config/cloudflare_ips.yml`
- Create: `config/initializers/trusted_proxies.rb`
- Create: `lib/tasks/trusted_proxies.rake`
- Create: `test/lib/trusted_proxies_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
require "test_helper"

# Behind Cloudflare the visitor's address is the LEFT-most X-Forwarded-For entry and the edge
# node is appended after it; Rails' RemoteIp returns the RIGHT-most address that is not a trusted
# proxy, so with only the default (private-range) proxies trusted, `request.remote_ip` was the
# edge node — every per-IP throttle keyed on Cloudflare (tinkerex#345, measured: four edge IPs for
# ten probes). Trusting Cloudflare's published ranges makes the visitor the answer there and
# changes nothing elsewhere: a direct request never carries a Cloudflare hop, and a forged
# X-Forwarded-For still loses to the right-most-untrusted rule.
class TrustedProxiesTest < ActiveSupport::TestCase
  PINNED = Rails.root.join("config/cloudflare_ips.yml")

  def configured_proxies = Rails.application.config.action_dispatch.trusted_proxies

  # Runs the real middleware with the app's real trusted-proxy list and returns what the app
  # would see as request.remote_ip.
  def remote_ip_for(remote_addr:, forwarded_for:)
    app = ->(env) { [ 200, {}, [ env["action_dispatch.remote_ip"].to_s ] ] }
    middleware = ActionDispatch::RemoteIp.new(app, false, configured_proxies)
    env = Rack::MockRequest.env_for("/", "REMOTE_ADDR" => remote_addr,
                                         "HTTP_X_FORWARDED_FOR" => forwarded_for)
    middleware.call(env).last.first
  end

  test "the pinned list is Cloudflare's, dated, and parses" do
    pinned = YAML.safe_load_file(PINNED)
    assert_match(/\A\d{4}-\d{2}-\d{2}\z/, pinned["fetched_on"].to_s, "the pin carries the date it was fetched")
    assert_operator pinned["ipv4"].size, :>=, 14, "Cloudflare publishes 14+ IPv4 ranges"
    assert_operator pinned["ipv6"].size, :>=, 6,  "Cloudflare publishes 6+ IPv6 ranges"
    (pinned["ipv4"] + pinned["ipv6"]).each { |range| IPAddr.new(range) } # raises on junk
    assert_includes pinned["ipv4"], "173.245.48.0/20"
    assert_includes pinned["ipv6"], "2606:4700::/32"
  end

  test "the app trusts the pinned ranges beside Rails' own defaults" do
    assert configured_proxies.any? { |p| p.include?(IPAddr.new("104.23.190.84")) }, "a measured edge node"
    assert configured_proxies.any? { |p| p.include?(IPAddr.new("127.0.0.1")) }, "Rails' defaults survive"
    assert configured_proxies.any? { |p| p.include?(IPAddr.new("192.168.1.7")) }, "the LAN front proxy stays trusted"
  end

  test "behind Cloudflare the visitor is the client, not the edge node" do
    assert_equal "203.0.113.9", remote_ip_for(remote_addr: "172.18.0.5",
                                              forwarded_for: "203.0.113.9, 104.23.190.84")
  end

  test "a non-Cloudflare hop is still the client — nothing else became trusted" do
    # The right-most untrusted address wins, so a forged left entry cannot impersonate anyone.
    assert_equal "198.51.100.7", remote_ip_for(remote_addr: "172.18.0.5",
                                               forwarded_for: "203.0.113.9, 198.51.100.7")
  end
end
```

- [ ] **Step 2: Run it** — `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/lib/trusted_proxies_test.rb` — expected: the first test errors (no file), the third fails with `"104.23.190.84"`.

- [ ] **Step 3: Pin the ranges**

`config/cloudflare_ips.yml` (the 14 + 6 ranges as published on 2026-10-13 at https://www.cloudflare.com/ips-v4 and https://www.cloudflare.com/ips-v6 — fetch them again with `curl -s https://www.cloudflare.com/ips-v4` rather than trusting this plan; they were, in order: 173.245.48.0/20, 103.21.244.0/22, 103.22.200.0/22, 103.31.4.0/22, 141.101.64.0/18, 108.162.192.0/18, 190.93.240.0/20, 188.114.96.0/20, 197.234.240.0/22, 198.41.128.0/17, 162.158.0.0/15, 104.16.0.0/13, 104.24.0.0/14, 172.64.0.0/13 and 2400:cb00::/32, 2606:4700::/32, 2803:f800::/32, 2405:b500::/32, 2405:8100::/32, 2a06:98c0::/29 — verify against the live lists):

```yaml
# Cloudflare's published egress ranges, trusted as proxies by config/initializers/trusted_proxies.rb.
# Refresh with `bin/rails trusted_proxies:refresh` (rewrites this file and the date). The date is
# load-bearing: test/lib/trusted_proxies_test.rb asserts the pin carries one.
fetched_on: "2026-10-13"
source:
  - https://www.cloudflare.com/ips-v4
  - https://www.cloudflare.com/ips-v6
ipv4:
  - 173.245.48.0/20
  # ... the rest, one per line, exactly as published
ipv6:
  - 2400:cb00::/32
  # ... the rest
```

`config/initializers/trusted_proxies.rb`:

```ruby
# CLOUDFLARE'S RANGES ARE TRUSTED PROXIES (tinkerex#345). ActionDispatch::RemoteIp answers
# `request.remote_ip` with the RIGHT-most X-Forwarded-For address that is not a trusted proxy. The
# OVH box sits behind Cloudflare, which appends its own edge address after the visitor's, and the
# default trusted list is private ranges only — so remote_ip was the EDGE NODE, and every per-IP
# rate_limit keyed on Cloudflare (measured 2026-10-13: four edge addresses for ten probes from one
# machine; the 11th login attempt answered 401 where the LAN answers 429). Trusting the published
# ranges makes the visitor the answer there and changes nothing elsewhere: a direct request never
# carries a Cloudflare hop, and a forged header still loses to the right-most-untrusted rule.
#
# NEVER key a throttle on CF-Connecting-IP alone: any request straight at the origin can forge it.
#
# Pinned, not fetched at boot: a boot must not depend on a third party being reachable (§14a's
# rule for the S3 guard). `bin/rails trusted_proxies:refresh` rewrites the pin and its date.
# Top-level initializer on purpose: nothing here needs an app constant, and the middleware reads
# this setting when the stack is built.
pinned = YAML.safe_load_file(Rails.root.join("config/cloudflare_ips.yml"))
cloudflare = (pinned.fetch("ipv4") + pinned.fetch("ipv6")).map { |range| IPAddr.new(range) }
Rails.application.config.action_dispatch.trusted_proxies =
  ActionDispatch::RemoteIp::TRUSTED_PROXIES + cloudflare
```

`lib/tasks/trusted_proxies.rake`:

```ruby
namespace :trusted_proxies do
  desc "Refresh config/cloudflare_ips.yml from Cloudflare's published lists (and stamp today's date)"
  task refresh: :environment do
    require "net/http"
    lists = { "ipv4" => "https://www.cloudflare.com/ips-v4", "ipv6" => "https://www.cloudflare.com/ips-v6" }
    ranges = lists.transform_values do |url|
      body = Net::HTTP.get_response(URI(url)).tap { |r| abort("#{url}: HTTP #{r.code}") unless r.is_a?(Net::HTTPSuccess) }.body
      body.lines.map(&:strip).reject(&:empty?).each { |r| IPAddr.new(r) } # raises on junk
    end
    # A short list is a truncated download, not a smaller Cloudflare.
    abort("ipv4 list too short (#{ranges['ipv4'].size})") if ranges["ipv4"].size < 10
    abort("ipv6 list too short (#{ranges['ipv6'].size})") if ranges["ipv6"].size < 4
    path = Rails.root.join("config/cloudflare_ips.yml")
    header = File.read(path).lines.take_while { |l| l.start_with?("#") }.join
    File.write(path, header + { "fetched_on" => Date.today.iso8601, "source" => lists.values,
                                 "ipv4" => ranges["ipv4"], "ipv6" => ranges["ipv6"] }.to_yaml.sub(/\A---\n/, ""))
    puts "pinned #{ranges['ipv4'].size} IPv4 + #{ranges['ipv6'].size} IPv6 ranges, fetched #{Date.today}"
  end
end
```

- [ ] **Step 4: Run** — expected all four PASS. Also run `bin/rails trusted_proxies:refresh` once locally and confirm `git diff config/cloudflare_ips.yml` is empty apart from the date (then `git checkout -- config/cloudflare_ips.yml` if the date moved, or keep it — either is fine; the pin must be the live list).

- [ ] **Step 5: Mutation-check** — replace the initializer's last statement with `ActionDispatch::RemoteIp::TRUSTED_PROXIES` alone (drop `+ cloudflare`); the "behind Cloudflare" test must fail with `"104.23.190.84"`. Restore, clear bootsnap, report the output.

- [ ] **Step 6: Commit** — subject "Cloudflare's published ranges are trusted proxies, so remote_ip is the visitor behind Cloudflare".

---

### Task 2: Mail by environment, registration mode, and the first owner

**Files:**
- Create: `lib/tinkerex/mail_settings.rb`, `lib/tinkerex/registration.rb`
- Create: `config/initializers/mail.rb`, `config/initializers/registration.rb`
- Modify: `config/initializers/devise.rb` (the `mailer_sender` line)
- Modify: `app/controllers/users/registrations_controller.rb`
- Modify: `app/views/users/shared/_links.html.erb`, `app/views/users/registrations/new.html.erb`, `app/views/users/confirmations/new.html.erb`
- Create: `app/views/users/registrations/closed.html.erb`
- Create: `test/lib/mail_settings_test.rb`, `test/lib/registration_test.rb`, `test/integration/web/registration_mode_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/lib/mail_settings_test.rb`:

```ruby
require "test_helper"

# Mail is configured by ENVIRONMENT, never by editing production.rb: SMTP_ADDRESS turns SMTP on and
# the other knobs refine it. The function is pure so this test needs no mailer and no boot.
class MailSettingsTest < ActiveSupport::TestCase
  test "unconfigured when SMTP_ADDRESS is unset" do
    assert_nil Tinkerex::MailSettings.from_env({})
    assert_not Tinkerex::MailSettings.configured?({ "SMTP_ADDRESS" => "" })
  end

  test "a bare address gets the defaults: 587, STARTTLS, the mail-link host as HELO domain, no auth" do
    s = Tinkerex::MailSettings.from_env({ "SMTP_ADDRESS" => "smtp.example.net", "APP_HOST" => "maker.example" })
    assert_equal({ address: "smtp.example.net", port: 587, domain: "maker.example", enable_starttls_auto: true }, s)
  end

  test "credentials add plain authentication, and every knob can be overridden" do
    s = Tinkerex::MailSettings.from_env({
      "SMTP_ADDRESS" => "smtp.example.net", "SMTP_PORT" => "2525", "SMTP_DOMAIN" => "mail.example",
      "SMTP_USER_NAME" => "u", "SMTP_PASSWORD" => "p", "SMTP_AUTHENTICATION" => "login", "SMTP_STARTTLS" => "false"
    })
    assert_equal({ address: "smtp.example.net", port: 2525, domain: "mail.example", user_name: "u",
                   password: "p", authentication: :login, enable_starttls_auto: false }, s)
  end

  test "the sender is MAIL_FROM, else no-reply at the mail-link host, else the historical literal" do
    assert_equal "hi@x.example", Tinkerex::MailSettings.sender({ "MAIL_FROM" => "hi@x.example", "APP_HOST" => "y" })
    assert_equal "no-reply@maker.example", Tinkerex::MailSettings.sender({ "APP_HOST" => "maker.example" })
    assert_equal "no-reply@tinkerex.app", Tinkerex::MailSettings.sender({})
  end
end
```

`test/lib/registration_test.rb`:

```ruby
require "test_helper"

# REGISTRATION is closed by default in production and open in development and test; `open` is
# refused on the single-library backends, where every account indexes the same files.
class RegistrationTest < ActiveSupport::TestCase
  test "the default mode is closed in production and open elsewhere" do
    assert_equal "closed", Tinkerex::Registration.mode({}, production: true)
    assert_equal "open",   Tinkerex::Registration.mode({}, production: false)
    assert_equal "open",   Tinkerex::Registration.mode({ "REGISTRATION" => "open" }, production: true)
  end

  test "validate! refuses an unknown mode and refuses open on share and s3" do
    assert_raises(Tinkerex::Registration::Error) { Tinkerex::Registration.validate!({ "REGISTRATION" => "maybe" }) }
    %w[share s3].each do |backend|
      e = assert_raises(Tinkerex::Registration::Error) do
        Tinkerex::Registration.validate!({ "REGISTRATION" => "open", "LIBRARY_BACKEND" => backend })
      end
      assert_match(/same library/, e.message)
    end
    assert_nil Tinkerex::Registration.validate!({ "REGISTRATION" => "open", "LIBRARY_BACKEND" => "chunk_remote" })
    assert_nil Tinkerex::Registration.validate!({ "REGISTRATION" => "closed", "LIBRARY_BACKEND" => "share" })
  end

  test "the state a visitor is in" do
    r = Tinkerex::Registration
    assert_equal :first_owner,  r.state(mode: "closed", users_exist: false, mail_configured: false)
    assert_equal :closed,       r.state(mode: "closed", users_exist: true,  mail_configured: true)
    assert_equal :open,         r.state(mode: "open",   users_exist: true,  mail_configured: true)
    assert_equal :open_no_mail, r.state(mode: "open",   users_exist: true,  mail_configured: false)
    assert_equal :first_owner,  r.state(mode: "open",   users_exist: false, mail_configured: false),
                 "the very first account never needs mail, whatever the mode"
  end
end
```

`test/integration/web/registration_mode_test.rb`:

```ruby
require "test_helper"

module Web
  # Registration closed (the production default): the FIRST account is the owner — created
  # confirmed, signed in, no mail — and the page closes behind it. Drives the real requests and
  # follows the redirects, because that is where the earlier sign-up defect lived (§14e).
  class RegistrationModeTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      ENV["REGISTRATION"] = "closed"
      User.delete_all
    end

    teardown { ENV.delete("REGISTRATION") }

    def sign_up(email)
      post user_registration_path, params: { user: { email:, password: PASSWORD, password_confirmation: PASSWORD } }
    end

    test "on an empty server the sign-up page says the first account becomes the owner" do
      get new_user_registration_path
      assert_response :success
      assert_select "form[action=?]", user_registration_path
      assert_match(/first account/i, response.body)
      assert_match(/owner/i, response.body)
    end

    test "the first account is confirmed without mail, signed in, and closes sign-up behind it" do
      assert_emails 0 do
        sign_up("owner@example.com")
      end
      owner = User.find_by!(email: "owner@example.com")
      assert owner.confirmed?, "the owner needs no confirmation mail"
      follow_redirect!
      assert_response :success, "signed in and landed on a real page, not bounced to the sign-in page"

      delete destroy_user_session_path
      get new_user_registration_path
      assert_response :forbidden
      assert_match(/closed/i, response.body)
      get new_user_session_path
      assert_select "a[href=?]", new_user_registration_path, count: 0, text: "Sign up"
    end

    test "a second sign-up on a closed server creates nothing" do
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_no_difference -> { User.count } do
        sign_up("stranger@example.com")
        assert_response :forbidden
      end
    end

    test "with registration open the usual confirmable flow is untouched" do
      ENV["REGISTRATION"] = "open"
      User.create!(email: "owner@example.com", password: PASSWORD, confirmed_at: Time.current)
      assert_emails 1 do
        sign_up("second@example.com")
      end
      assert_not User.find_by!(email: "second@example.com").confirmed?
    end
  end
end
```

- [ ] **Step 2: Run them** — expected: NameError on `Tinkerex::MailSettings` / `Tinkerex::Registration`; the integration tests fail on the missing page text and the 403s.

- [ ] **Step 3: The two modules**

`lib/tinkerex/mail_settings.rb`:

```ruby
module Tinkerex
  # Mail is configured by ENVIRONMENT, never by editing production.rb (which shipped the scaffold's
  # commented smtp_settings for a year, so no deployment could send a confirmation). SMTP_ADDRESS
  # turns SMTP on; everything else has the common default. Pure: the initializer applies it.
  module MailSettings
    def self.configured?(env = ENV) = env["SMTP_ADDRESS"].to_s.strip.present?

    # The Hash ActionMailer::Base.smtp_settings takes, or nil when mail is not configured.
    def self.from_env(env = ENV)
      return nil unless configured?(env)

      settings = {
        address: env["SMTP_ADDRESS"].strip,
        port: Integer(env["SMTP_PORT"].presence || 587),
        domain: (env["SMTP_DOMAIN"].presence || env["APP_HOST"].presence)
      }.compact
      if env["SMTP_USER_NAME"].present?
        settings[:user_name] = env["SMTP_USER_NAME"]
        settings[:password] = env["SMTP_PASSWORD"].to_s
        settings[:authentication] = (env["SMTP_AUTHENTICATION"].presence || "plain").to_sym
      end
      settings[:enable_starttls_auto] = env["SMTP_STARTTLS"].to_s.strip.downcase != "false"
      settings
    end

    # The From address: MAIL_FROM, else no-reply at the mail-link host, else the historical literal
    # (kept so a deployment that sets neither still sends from a syntactically valid address).
    def self.sender(env = ENV)
      env["MAIL_FROM"].presence || (env["APP_HOST"].present? ? "no-reply@#{env['APP_HOST']}" : "no-reply@tinkerex.app")
    end
  end
end
```

`lib/tinkerex/registration.rb`:

```ruby
module Tinkerex
  # Whether strangers may create accounts, and who the first account is.
  #
  # CLOSED BY DEFAULT IN PRODUCTION. On `share` and `s3` every account indexes the SAME library
  # (Library::ScanJob.scan_all! walks one root for every user; FileLayer::Share/S3 carry no user
  # segment), so an open sign-up hands a stranger read, write and delete on the owner's files —
  # `open` is REFUSED there at boot. `open` is for chunk_remote (per-user remote libraries, §8)
  # and the managed service.
  #
  # THE FIRST ACCOUNT IS THE OWNER. With no user in the database the sign-up page is allowed once,
  # and the account it creates is confirmed on the spot: a self-hoster has no mail server on day
  # one, and the alternative — a console incantation before the first page works — is the thing
  # a stranger never finds. After that the page closes (403) unless REGISTRATION=open.
  module Registration
    Error = Class.new(StandardError)
    MODES = %w[open closed].freeze
    SINGLE_LIBRARY_BACKENDS = %w[share s3].freeze

    def self.mode(env = ENV, production: Rails.env.production?)
      env["REGISTRATION"].presence || (production ? "closed" : "open")
    end

    # Raises for an unknown mode, and for `open` on a backend where every account is one library.
    # Returns nil when the configuration is acceptable. Called at boot (config/initializers/
    # registration.rb) and unit-tested directly; reads only ENV so it needs no app constant.
    def self.validate!(env = ENV, production: Rails.env.production?)
      m = mode(env, production:)
      raise Error, "REGISTRATION=#{m.inspect} is not one of #{MODES.join('/')}" unless MODES.include?(m)

      backend = env["LIBRARY_BACKEND"].to_s
      if m == "open" && SINGLE_LIBRARY_BACKENDS.include?(backend)
        raise Error, "REGISTRATION=open is refused on LIBRARY_BACKEND=#{backend}: every account " \
                     "indexes the same library there, so an open sign-up hands a stranger the " \
                     "owner's files. Leave it closed (the first account is the owner; " \
                     "bin/rails tinkerex:owner adds more) or deploy chunk_remote."
      end
      nil
    end

    def self.open?(env: ENV, users_exist: User.exists?)
      mode(env) == "open" || !users_exist
    end

    def self.first_owner?(users_exist: User.exists?) = !users_exist

    # What the sign-up page should tell the visitor.
    def self.state(mode: self.mode, users_exist: User.exists?, mail_configured: MailSettings.configured?)
      return :first_owner unless users_exist
      return :closed if mode == "closed"

      mail_configured ? :open : :open_no_mail
    end
  end
end
```

- [ ] **Step 4: The initializers and Devise's sender**

`config/initializers/mail.rb`:

```ruby
# MAIL BY ENVIRONMENT (B, 2026-10-13). production.rb shipped the scaffold's commented smtp_settings
# for a year, so no deployment could send a confirmation or a reset; with Devise :confirmable that
# meant nobody could finish signing up. SMTP_ADDRESS turns SMTP on (lib/tinkerex/mail_settings.rb
# lists the knobs). Production only: development and test keep their own delivery methods.
# after_initialize, like library_backend_check.rb: ActionMailer::Base is loaded by then, and the
# settings are class attributes read at delivery time.
Rails.application.config.after_initialize do
  next unless Rails.env.production?

  if (settings = Tinkerex::MailSettings.from_env)
    ActionMailer::Base.delivery_method = :smtp
    ActionMailer::Base.smtp_settings = settings
  else
    Rails.logger.warn("SMTP_ADDRESS is not set: confirmation and password-reset mail cannot be sent. " \
                      "The first account (the owner) needs no mail; set SMTP_ADDRESS before opening " \
                      "sign-ups or inviting a second account. bin/rails tinkerex:owner and " \
                      "tinkerex:password are the console doors meanwhile.")
  end
end
```

`config/initializers/registration.rb`:

```ruby
# REGISTRATION=open ON A SINGLE-LIBRARY BACKEND IS REFUSED AT BOOT (lib/tinkerex/registration.rb
# says why). The same shape as library_backend_check.rb: a misconfiguration that would only show
# on the first stranger's sign-up is worse than one that stops the boot. Skipped in test, where
# the unit test drives validate! directly.
require "tinkerex/registration"

Rails.application.config.after_initialize do
  Tinkerex::Registration.validate! unless Rails.env.test?
end
```

`config/initializers/devise.rb` — replace the `config.mailer_sender = "no-reply@tinkerex.app"` line (keep its surrounding comment, add one sentence) with:

```ruby
  require "tinkerex/mail_settings"
  # MAIL_FROM, else no-reply at APP_HOST, else the historical literal — one owner for the address
  # (devise_auth_flow_test pins that every message agrees with it).
  config.mailer_sender = Tinkerex::MailSettings.sender
```

- [ ] **Step 5: The controller and the views**

`app/controllers/users/registrations_controller.rb` — add, directly after the `rate_limit` block:

```ruby
    # CLOSED BY DEFAULT IN PRODUCTION, AND THE FIRST ACCOUNT IS THE OWNER (Tinkerex::Registration
    # has the argument). A closed server answers the sign-up page with a 403 that says so, rather
    # than a 404 that pretends the route does not exist — a visitor who was sent here by the
    # person running the box should learn to ask them, not to retype the address.
    before_action :require_registration_open!, only: %i[new create]

    # The first account is confirmed on the spot: a self-hoster has no mail server on day one,
    # and Devise's own create path (build, save, then branch on active_for_authentication?)
    # signs a confirmed account straight in. skip_confirmation! must run BEFORE save, which is
    # why this hooks build_resource rather than an after_create.
    def build_resource(hash = {})
      super
      resource.skip_confirmation! if Tinkerex::Registration.first_owner?
    end

    private

    def require_registration_open!
      return if Tinkerex::Registration.open?

      render "users/registrations/closed", status: :forbidden
    end
```

(The existing `create` and `destroy` stay as they are; put `build_resource` and the private section below them, keeping `destroy` above `private`.)

`app/views/users/registrations/closed.html.erb`:

```erb
<div class="auth-card">
  <div class="brand"><span class="brand-mark" aria-hidden="true"></span><span class="brand-name">Tinkerex</span></div>
  <h2>Sign-ups are closed</h2>
  <p>This server is not taking new accounts. If someone runs it for you, ask them for an account; the person running it can add one with <code>bin/rails tinkerex:owner</code> or open sign-ups with <code>REGISTRATION=open</code>.</p>
  <%= render "users/shared/links" %>
</div>
```

`app/views/users/registrations/new.html.erb` — after the `<h2>Sign up</h2>` line, add:

```erb
  <% case Tinkerex::Registration.state
     when :first_owner %>
    <p class="auth-note">This is the server's first account. It becomes the owner and needs no email confirmation; sign-ups close after it unless <code>REGISTRATION=open</code> is set.</p>
  <% when :open_no_mail %>
    <p class="auth-note">This server can't send email yet, so a new account can't be confirmed. Ask whoever runs it to set <code>SMTP_ADDRESS</code>, or to create your account for you.</p>
  <% end %>
```

`app/views/users/confirmations/new.html.erb` — after its `<h2>` line, add:

```erb
  <% unless Tinkerex::MailSettings.configured? %>
    <p class="auth-note">This server can't send email yet (<code>SMTP_ADDRESS</code> is not set), so nothing will arrive until whoever runs it configures mail.</p>
  <% end %>
```

`app/views/users/shared/_links.html.erb` — change the sign-up branch to:

```erb
  <%- if devise_mapping.registerable? && controller_name != 'registrations' && Tinkerex::Registration.open? %>
    <li><%= link_to "Sign up", new_registration_path(resource_name) %></li>
  <% end %>
```

If `auth-note` is not a class `app/assets/stylesheets/components.css` already defines, reuse the existing `auth-hint` class instead of inventing one (docs/invariants/design-system.md: a component selector is defined in components.css and nowhere else).

- [ ] **Step 6: Run** — the three new files plus `test/integration/web/registration_flow_test.rb test/integration/web/devise_auth_flow_test.rb test/integration/web/auth_pages_test.rb test/integration/web/account_enumeration_test.rb test/integration/web/auth_throttle_test.rb` — expected all PASS (test env defaults to open, so the existing flows are unchanged; `auth_pages_test` renders the sign-up page with no users, which is now the first-owner page — still a 200 with the form).

- [ ] **Step 7: Mutation-check** — (a) make `open?` return `true` unconditionally: "a second sign-up on a closed server creates nothing" RED; (b) remove the `skip_confirmation!` line: "the first account is confirmed without mail" RED; (c) remove the share/s3 branch from `validate!`: the unit test RED; (d) return `nil` from `from_env` always: the mail unit test RED. Restore each, clear bootsnap, report outputs.

- [ ] **Step 8: Commit** — subject "Registration is closed by default, the first account is the owner, and mail is configured by environment".

---

### Task 3: Console doors for an owner without mail, and the deploy-hygiene guard

**Files:**
- Create: `lib/tasks/tinkerex.rake`
- Create: `test/tasks/tinkerex_tasks_test.rb` (mirror `test/tasks/projects_sweep_pointers_test.rb` for how a task is loaded and invoked)
- Modify: `test/deploy_hygiene_test.rb` (one new test after "no committed destination opens the unverified test-signup seam")
- Modify: `config/deploy.ovh.yml` (one explicit line) and `config/deploy.yml` (one comment)

- [ ] **Step 1: Write the failing tests**

`test/tasks/tinkerex_tasks_test.rb`:

```ruby
require "test_helper"
require "rake"

# The console doors for an owner whose server has no mail: create a confirmed account, reset a
# password. The password comes from TINKEREX_PASSWORD, never argv (argv is in `ps` and shell
# history), and the tasks refuse the cases a human gets wrong at 2 a.m.
class TinkerexTasksTest < ActiveSupport::TestCase
  PASSWORD = "correct horse battery staple".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("tinkerex:owner")
    Rake::Task["tinkerex:owner"].reenable
    Rake::Task["tinkerex:password"].reenable
    ENV["TINKEREX_PASSWORD"] = PASSWORD
  end

  teardown { ENV.delete("TINKEREX_PASSWORD") }

  test "owner creates a confirmed account that can sign in" do
    assert_difference -> { User.count }, 1 do
      Rake::Task["tinkerex:owner"].invoke("maker@example.com")
    end
    u = User.find_by!(email: "maker@example.com")
    assert u.confirmed?
    assert u.valid_password?(PASSWORD)
  end

  test "owner refuses an existing address and a short password" do
    User.create!(email: "taken@example.com", password: PASSWORD, confirmed_at: Time.current)
    assert_raises(SystemExit) { Rake::Task["tinkerex:owner"].invoke("taken@example.com") }
    Rake::Task["tinkerex:owner"].reenable
    ENV["TINKEREX_PASSWORD"] = "short"
    assert_no_difference -> { User.count } do
      assert_raises(SystemExit) { Rake::Task["tinkerex:owner"].invoke("new@example.com") }
    end
  end

  test "password resets and confirms an existing account" do
    u = User.create!(email: "lost@example.com", password: "old password here!!")
    Rake::Task["tinkerex:password"].invoke("lost@example.com")
    u.reload
    assert u.confirmed?
    assert u.valid_password?(PASSWORD)
  end
end
```

In `test/deploy_hygiene_test.rb`, after the test-signup test:

```ruby
  test "no committed destination opens registration on a single-library backend" do
    # Tinkerex::Registration refuses REGISTRATION=open at boot on share and s3 (every account
    # indexes the same library). This pins the same rule one step earlier, on the MERGED deploy
    # config, so the refusal is never first discovered as a crash loop on the box.
    require "kamal"
    LIBRARY_DESTINATIONS.each do |destination|
      clear = at(Kamal::Configuration.create_from(
        config_file: ROOT.join("config/deploy.yml"), destination: destination
      ).raw_config, "env", "clear").to_h
      assert clear.key?("LIBRARY_BACKEND"), "#{destination || 'base'}: raw_config shape changed?"
      next unless %w[share s3].include?(clear["LIBRARY_BACKEND"].to_s)

      assert_not_equal "open", clear["REGISTRATION"].to_s,
                       "#{destination || 'base'} runs LIBRARY_BACKEND=#{clear['LIBRARY_BACKEND']} and sets " \
                       "REGISTRATION=open: every account there indexes the same library"
    end
  end
```

- [ ] **Step 2: Run** — expected: the task test errors (no task); the hygiene test passes vacuously-but-honestly (no destination sets REGISTRATION) — its mutation check is what proves it.

- [ ] **Step 3: The rake file**

`lib/tasks/tinkerex.rake`:

```ruby
# Console doors for a server with no mail (docs/DEPLOY.md "Accounts"). The password is read from
# TINKEREX_PASSWORD so it never sits in argv — `ps`, shell history and the deploy log all see argv.
namespace :tinkerex do
  def tinkerex_password!
    pw = ENV["TINKEREX_PASSWORD"].to_s
    abort "set TINKEREX_PASSWORD (#{Devise.password_length.min}+ characters); never pass it on the command line" if pw.length < Devise.password_length.min
    pw
  end

  desc "Create a confirmed account: bin/rails tinkerex:owner[EMAIL] with TINKEREX_PASSWORD set"
  task :owner, [ :email ] => :environment do |_t, args|
    email = args[:email].to_s.strip.downcase
    abort "usage: bin/rails tinkerex:owner[EMAIL]" if email.blank?
    abort "#{email} already exists — use tinkerex:password[EMAIL] to reset it" if User.exists?(email:)
    pw = tinkerex_password!
    User.create!(email:, password: pw, confirmed_at: Time.current)
    puts "created #{email} (confirmed)"
  end

  desc "Reset a password and confirm the account: bin/rails tinkerex:password[EMAIL] with TINKEREX_PASSWORD set"
  task :password, [ :email ] => :environment do |_t, args|
    email = args[:email].to_s.strip.downcase
    u = User.find_by(email:) or abort "no account #{email.inspect}"
    pw = tinkerex_password!
    u.update!(password: pw, confirmed_at: u.confirmed_at || Time.current)
    puts "#{email} updated"
  end
end
```

`config/deploy.ovh.yml` — in `env: clear:` beside `APP_HOST: tinkerex.com`:

```yaml
    # Closed is the production default; stated here because this box is the one strangers reach
    # and runs a single-library backend (s3), where `open` is refused at boot anyway.
    REGISTRATION: closed
```

`config/deploy.yml` — one comment line in `env: clear:` under the APP_HOST block: `# REGISTRATION is not set: closed is the production default (lib/tinkerex/registration.rb); the first account is the owner.`

- [ ] **Step 4: Run** — the task test and `test/deploy_hygiene_test.rb` — expected PASS.

- [ ] **Step 5: Mutation-check** — put `REGISTRATION: open` in `config/deploy.share.yml`'s env.clear: the hygiene test RED naming share; restore. Remove the `confirmed_at:` from the owner task: "owner creates a confirmed account" RED; restore.

- [ ] **Step 6: Commit** — subject "Console doors for an owner without mail, and no single-library destination opens registration".

---

### Task 4 (orchestrator): docs, merge, gates, PR

- `docs/DEPLOY.md`: a new section "Accounts: who can sign up, the first owner, and mail" — the `REGISTRATION` modes and the share/s3 refusal; the first-owner flow; `SMTP_ADDRESS` + the knobs and `MAIL_FROM`; the two rake tasks (with `TINKEREX_PASSWORD=... bin/rails tinkerex:owner[...]` spelled out); the OVH `--hosts 15.204.216.249` deploy flag (tinkerex#346) in the OVH deploy line.
- `CLAUDE.md` §8: after the "Registration creates a new account only" sentence, add: "**Registration is closed by default in production; the first account is the owner (confirmed without mail); `REGISTRATION=open` is refused at boot on `share` and `s3`**, where every account indexes one library — `lib/tinkerex/registration.rb`, pinned by `test/deploy_hygiene_test.rb` and `test/integration/web/registration_mode_test.rb`." Mind the line ceiling in `test/docs_hygiene_test.rb`.
- `docs/AUDIT-2026-10-12-readiness.md`: mark §1 items 1, 2 and §2.1 item 6 fixed by B; §1 item 5's residual (#345) fixed.
- Merge the three implementer branches into `claude/b-accounts`, run `TINKEREX_SYNC_DIR=/Users/charlesschwartz/Desktop/repos/tinkerex-sync bin/ci`, three legs identical, then `/finish-branch` and `bin/log arc --from-pr <n>`; close #345 at merge.
