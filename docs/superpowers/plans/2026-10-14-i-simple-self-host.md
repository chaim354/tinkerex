# I — Self-host in one file: implementation plan

> **For agentic workers:** execute with `.claude/commands/execute-plan.md` (this repo's default: one
> task = one unit owned end-to-end by one implementer, independent tasks in parallel, no
> spec-compliance stage, one capped quality review per task). Steps use checkbox (`- [ ]`) syntax.
> Spec: `docs/superpowers/specs/2026-10-14-i-simple-self-host-design.md`.

**Goal:** a stranger with Docker on a Mac, Windows or Linux machine downloads one compose file,
runs `docker compose up -d`, and has Tinkerex with the Tools gallery at `localhost:8080` with
nothing generated, edited or chowned first.

**Architecture:** four image-side changes remove the four hand-set settings — the backend and path
become Dockerfile defaults, the session secret is generated once into the storage volume
(`Tinkerex::SecretKeyBase`), `APP_HOST` is validated only alongside SMTP
(`Tinkerex::MailSettings.validate!`), and the entrypoint takes `PUID`/`PGID` and drops privileges
with `setpriv`. The compose file pulls four ghcr images with no `build:` and an optional `.env`;
`docker-compose.build.yml` is the from-source overlay. The Kamal builder goes multi-arch.

**Tech stack:** Rails 8.1.3.1, bash entrypoint, Docker Compose 2.24+, Kamal 2.12, Minitest.

---

## Facts the tasks rely on (verified 2026-10-14 against `main` c68ba86f)

- `config/environments/production.rb:116-119` builds mailer `default_url_options` from `APP_HOST`;
  the only other readers are `lib/tinkerex/mail_settings.rb:20,34`.
- Rails' `config.secret_key_base=` takes any non-blank String; `nil` in production raises "Missing
  secret_key_base" (`railties/lib/rails/application/configuration.rb:535-545`). Its getter, left
  alone, resolves `SECRET_KEY_BASE_DUMMY` → throwaway, else ENV, else credentials.
- `Rails.application.credentials` is usable inside `Rails.application.configure` (the scaffold's own
  commented smtp lines in production.rb do it). With no master key the credentials read as empty.
- `config/initializers/devise.rb:17` leaves `config.secret_key` commented: Devise derives from
  `secret_key_base`.
- `config/initializers/mail.rb` applies `Tinkerex::MailSettings.from_env` in production inside
  `after_initialize`; `config/initializers/registration.rb` is the validate-at-boot pattern.
- `lib/library_backend_check.rb:182-194` is `check_share!`; `test/lib/library_backend_check_test.rb:22-26`
  pins the "does not exist" wording.
- `Dockerfile:174-176` creates `rails` 1000:1000 and switches `USER 1000:1000`; the F3D comment at
  `Dockerfile:205-210` justifies `F3D_BIN` partly by that `USER` line. The base image is Debian 13
  (trixie) and ships `/usr/bin/setpriv`; no `gosu`.
- `bin/docker-entrypoint` is 8 lines: `db:prepare` when the last two args are `./bin/rails server`,
  then `exec`.
- `docker-compose.yml` today: `web` with `build: .`, `env_file: .env` (required), `LIBRARY_BACKEND`/
  `LIBRARY_PATH` in `environment`, and three services behind `profiles: [tools]` that build from
  `sidecar/` and `../tinkerex-addons`. The Kamal accessories wire the same three images as
  `http://tinkerex-boxes:8000`, `http://tinkerex-openscad:8000`, `http://tinkerex-addons`
  (`config/deploy.yml:143-156`, `:250-275`).
- `test/install_docs_test.rb:67-76` scans `docker-compose.yml`, `docker-compose.chunk_remote.yml`
  and `.env.example` for `NAME=` / `NAME:` and requires a row in INSTALL.md's table for each;
  `:58-65` scans `app lib config bin/docker-entrypoint bin/thrust` for `ENV[...]`/`env.fetch(...)`.
  Shell `$PUID` does not match that pattern; the compose scan is what forces the `PUID`/`PGID` rows.
- `config/deploy.yml:224-225` is `builder: arch: amd64`; `test/deploy_hygiene_test.rb` reads only
  `builder.secrets` from that block.
- Tests run with `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test <file>`. There is
  no `Object#stub`; the house pattern is a local `replacing` helper. Nothing here needs one.
- `.env.example` today sets `RAILS_MAX_THREADS=16` uncommented, so the container has run 16 threads;
  the audit (§2.1.5) records that Puma's stock 3 starves once a sidecar is proxied. The compose file
  takes over that default.

## File map

| task | creates | modifies | test |
|---|---|---|---|
| 1 | `lib/tinkerex/secret_key_base.rb` | `config/environments/production.rb` | `test/lib/secret_key_base_test.rb` (new) |
| 2 | — | `lib/tinkerex/mail_settings.rb`, `config/initializers/mail.rb` | `test/lib/mail_settings_test.rb` |
| 3 | — | `lib/library_backend_check.rb` | `test/lib/library_backend_check_test.rb` |
| 4 | `test/docker_entrypoint_test.rb` | `Dockerfile`, `bin/docker-entrypoint` | same |
| 5 | `docker-compose.build.yml`, `test/compose_hygiene_test.rb` | `docker-compose.yml`, `test/install_docs_test.rb` | same |
| 6 | — | `README.md`, `docs/INSTALL.md`, `.env.example`, `docs/superpowers/plans/2026-10-14-i-install-and-onboarding-handoff.md` | `test/install_docs_test.rb` (existing) |
| 7 | — | `unraid/tinkerex.xml` | none (XML; reviewed by eye) |
| 8 | — | `config/deploy.yml` | `test/deploy_hygiene_test.rb` (existing, must stay green) |
| 9 | — | — | the real runs (orchestrator) |

Tasks 1–8 touch disjoint paths and run in parallel. Task 9 runs after they are merged.

---

### Task 1: `Tinkerex::SecretKeyBase` — generated once, kept in the volume

**Files:**
- Create: `lib/tinkerex/secret_key_base.rb`
- Create: `test/lib/secret_key_base_test.rb`
- Modify: `config/environments/production.rb` (after line 4, the "Settings specified here" comment; and the `require` at line 1)

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/secret_key_base_test.rb
require "test_helper"
require "tmpdir"

# The session secret needs no hand-set value: ENV wins, then the credential, then a file generated
# once into storage/ (the persistent volume). Pure apart from that file, so this test needs no boot
# and drives it against a temp directory; production.rb assigns the result (the design says why).
class SecretKeyBaseTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir("secret")
    @messages = []
    @log = ->(m) { @messages << m }
  end

  teardown { FileUtils.remove_entry(@dir) }

  def resolve(env = {}, credential: nil)
    Tinkerex::SecretKeyBase.resolve(env: env, credential: credential, dir: @dir, log: @log)
  end

  def file = File.join(@dir, "secret_key_base")

  test "the environment wins, and a blank value counts as unset" do
    assert_equal "from-env", resolve({ "SECRET_KEY_BASE" => "from-env" })
    assert_not File.exist?(file), "an ENV secret must not write the file"
    assert_match(/\A\h{128}\z/, resolve({ "SECRET_KEY_BASE" => " " }),
                 ".env.example shipped SECRET_KEY_BASE= as a line to fill in; blank is unset")
  end

  test "the credential wins over the file" do
    assert_equal "from-credential", resolve({}, credential: "from-credential")
    assert_not File.exist?(file)
  end

  test "generated once, mode 0600, announced once, reused on the next boot" do
    first = resolve
    assert_match(/\A\h{128}\z/, first)
    assert_equal 0o600, File.stat(file).mode & 0o777
    assert_equal [ first ], [ File.read(file).strip ]
    assert_equal 1, @messages.size
    assert_includes @messages.first, file
    assert_includes @messages.first, "SECRET_KEY_BASE"
    assert_equal first, resolve, "the second boot must read the file, never generate again"
    assert_equal 1, @messages.size, "and say nothing the second time"
  end

  test "an unwritable directory raises, naming the file and the override" do
    skip "root ignores mode bits" if Process.uid.zero?
    FileUtils.chmod(0o500, @dir)
    e = assert_raises(Tinkerex::SecretKeyBase::Error) { resolve }
    assert_includes e.message, file
    assert_includes e.message, "SECRET_KEY_BASE"
  ensure
    FileUtils.chmod(0o700, @dir)
  end

  test "the precompile boot gets nothing, so Rails' own throwaway stands and nothing is written" do
    assert_nil resolve({ "SECRET_KEY_BASE_DUMMY" => "1" })
    assert_not File.exist?(file)
  end
end
```

- [ ] **Step 2: Run it, expect NameError**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/lib/secret_key_base_test.rb`
Expected: 5 errors, `uninitialized constant Tinkerex::SecretKeyBase`.

- [ ] **Step 3: Write the module**

```ruby
# lib/tinkerex/secret_key_base.rb
require "securerandom"
require "fileutils"

module Tinkerex
  # THE SESSION SECRET, GENERATED ON FIRST BOOT AND KEPT IN THE VOLUME (I, 2026-10-14). Rails refuses
  # to boot in production without a secret_key_base, and a stranger's image has no master key for
  # the committed credentials, so until now every install began with `openssl rand -hex 64` pasted
  # into .env. The order now: SECRET_KEY_BASE from the environment -- a BLANK counts as unset, because
  # .env.example shipped `SECRET_KEY_BASE=` as a line to fill in and an old .env may still carry it --
  # else the credential (the author's deployments, which hold the master key), else a file in
  # storage/, read if present and generated once if not. storage/ is the persistent volume, beside
  # production.sqlite3: whoever holds the volume holds the database already, and restoring the
  # volume restores sessions with it.
  #
  # production.rb assigns the result to config.secret_key_base, whose setter takes any non-blank
  # String; Devise derives its own key from it. SKIPPED under SECRET_KEY_BASE_DUMMY, the image
  # build's assets:precompile: Rails generates a throwaway there, and a secret written during the
  # build would bake into the image layer.
  #
  # Failure is loud. A storage directory that cannot be written raises with the path and the
  # override, never a per-boot random value that would sign everyone out on every restart.
  module SecretKeyBase
    Error = Class.new(StandardError)
    FILE = "secret_key_base".freeze

    def self.resolve(dir:, env: ENV, credential: nil, log: ->(msg) { warn(msg) })
      return nil if env["SECRET_KEY_BASE_DUMMY"].present?

      from_env = env["SECRET_KEY_BASE"].to_s.strip
      return from_env if from_env.present?
      return credential if credential.to_s.strip.present?

      from_file(File.join(dir.to_s, FILE), log:)
    end

    def self.from_file(path, log:)
      existing = File.read(path).strip if File.file?(path)
      return existing if existing.present?

      secret = SecureRandom.hex(64)
      write_atomically(path, secret)
      log.call("Generated a session secret and kept it at #{path}. Set SECRET_KEY_BASE to use your own instead.")
      secret
    rescue SystemCallError => e
      raise Error, "cannot read or create the session secret at #{path} (#{e.class}: #{e.message}). " \
                   "The storage volume must be writable by the user the app runs as (PUID), or set " \
                   "SECRET_KEY_BASE in the environment."
    end

    # Temp-then-rename so a crash mid-write never leaves a half-written secret to be read as the
    # whole one; EXCL + 0600 so the file is never readable by anyone else, even for an instant.
    def self.write_atomically(path, secret)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.#{Process.pid}.tmp"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |f| f.write(secret) }
      File.rename(tmp, path)
    ensure
      File.unlink(tmp) if tmp && File.exist?(tmp)
    end
    private_class_method :write_atomically
  end
end
```

- [ ] **Step 4: Run the test, expect 5 passes**

Same command. Expected: `5 runs, … 0 failures, 0 errors` (the chmod test skips when run as root).

- [ ] **Step 5: Wire it in production.rb**

Line 1 becomes two requires:

```ruby
require "active_support/core_ext/integer/time"
require "tinkerex/secret_key_base"
```

Directly after line 4 (`# Settings specified here will take precedence over those in config/application.rb.`) insert:

```ruby

  # THE SESSION SECRET NEEDS NO HAND-SET VALUE (I, 2026-10-14; lib/tinkerex/secret_key_base.rb has
  # the order and the reasons). Assigned here rather than left to Rails' own getter because that
  # getter raises in production when neither the environment nor the credentials carry one, and a
  # stranger's image carries neither. A nil answer (the precompile's SECRET_KEY_BASE_DUMMY boot)
  # leaves the getter alone, which is exactly the throwaway Rails wants there.
  if (secret = Tinkerex::SecretKeyBase.resolve(dir: Rails.root.join("storage"),
                                                credential: Rails.application.credentials.secret_key_base))
    config.secret_key_base = secret
  end
```

- [ ] **Step 6: Prove the wiring boots**

Run, from the repo root with a scratch storage dir so nothing lands in the real `storage/`:

```sh
d=$(mktemp -d); mkdir -p "$d/lib" "$d/storage"
RAILS_ENV=production SECRET_KEY_BASE= LIBRARY_BACKEND=share LIBRARY_PATH="$d/lib" \
  bin/rails runner 'puts Rails.application.secret_key_base.size' 2>&1 | tail -3
ls -l storage/secret_key_base
```

Expected: a line `Generated a session secret and kept it at …/storage/secret_key_base…`, then `128`,
and the file exists with mode `-rw-------`. Then **delete it**: `rm storage/secret_key_base` (it is
gitignored under `/storage/*`, but it must not sit in the working tree). Run the same command with
`SECRET_KEY_BASE=abc` and expect `3` and no file.

- [ ] **Step 7: Mutation-check, then restore each**

1. In `resolve`, change `from_env.present?` to `!from_env.nil?` → "blank counts as unset" must fail. Restore.
2. Remove the `0o600` mode from `File.open` → the mode assertion must fail. Restore.
3. Remove `return existing if existing.present?` → "reused on the next boot" must fail. Restore.
4. Remove the `SECRET_KEY_BASE_DUMMY` line → the precompile test must fail. Restore.

Report each actual failure line. Restore with `git checkout -- lib/tinkerex/secret_key_base.rb`
only after the file is committed (Step 8 first if needed), and clear `tmp/cache/bootsnap*` after a
restore before the green run.

- [ ] **Step 8: Commit**

```sh
git add lib/tinkerex/secret_key_base.rb test/lib/secret_key_base_test.rb config/environments/production.rb
git commit -F - <<'MSG'
The session secret is generated on first boot and kept in the volume

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 2: `Tinkerex::MailSettings.validate!` — SMTP without a host is refused

**Files:**
- Modify: `lib/tinkerex/mail_settings.rb` (add `Error` and `validate!`)
- Modify: `config/initializers/mail.rb` (call it inside the production block)
- Test: `test/lib/mail_settings_test.rb` (append two tests)

- [ ] **Step 1: Append the failing tests**

```ruby
  test "SMTP without APP_HOST is refused at boot, naming both; with a host, or without SMTP, it passes" do
    e = assert_raises(Tinkerex::MailSettings::Error) do
      Tinkerex::MailSettings.validate!({ "SMTP_ADDRESS" => "smtp.example.net" })
    end
    assert_includes e.message, "APP_HOST"
    assert_includes e.message, "SMTP_ADDRESS"
    assert_raises(Tinkerex::MailSettings::Error) do
      Tinkerex::MailSettings.validate!({ "SMTP_ADDRESS" => "smtp.example.net", "APP_HOST" => " " })
    end
    assert_nil Tinkerex::MailSettings.validate!({ "SMTP_ADDRESS" => "smtp.example.net", "APP_HOST" => "maker.example" })
    assert_nil Tinkerex::MailSettings.validate!({})
    assert_nil Tinkerex::MailSettings.validate!({ "APP_HOST" => "" }), "no SMTP: the host is not needed at all"
  end

  test "the mail initializer validates before it applies, so the refusal is a boot refusal" do
    source = Rails.root.join("config/initializers/mail.rb").read
    assert_includes source, "Tinkerex::MailSettings.validate!"
    assert_operator source.index("Tinkerex::MailSettings.validate!"), :<, source.index("Tinkerex::MailSettings.from_env"),
                    "validate! must run before from_env applies the settings"
  end
```

- [ ] **Step 2: Run, expect NoMethodError / NameError**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/lib/mail_settings_test.rb`
Expected: the two new tests error (`uninitialized constant Tinkerex::MailSettings::Error`, and the
source assertion fails).

- [ ] **Step 3: Add `Error` and `validate!`**

In `lib/tinkerex/mail_settings.rb`, directly after `module MailSettings` (line 5) insert:

```ruby
    Error = Class.new(StandardError)

```

and after `deliverable?` (line 11) insert:

```ruby

    # SMTP WITHOUT A HOST NAME IS REFUSED AT BOOT (I, 2026-10-14). APP_HOST feeds the links in every
    # message, the HELO domain and the default sender, and nothing else in the app -- so it is
    # required exactly when mail is, and an install that never sets SMTP_ADDRESS never sets it. The
    # same shape as library_backend_check.rb: a confirmation link to APP_HOST-IS-NOT-SET.invalid in
    # the one email a new account must click is worse than a boot that stops and says so.
    def self.validate!(env = ENV)
      return nil unless configured?(env)
      return nil if env["APP_HOST"].to_s.strip.present?

      raise Error, "SMTP_ADDRESS is set but APP_HOST is not: the links in confirmation and " \
                   "password-reset mail need the host name people reach this server at " \
                   "(maker.example.net or 192.168.1.20, no scheme). Set APP_HOST, or unset " \
                   "SMTP_ADDRESS to run without mail."
    end
```

- [ ] **Step 4: Wire the initializer**

In `config/initializers/mail.rb`, after `next unless Rails.env.production?` and its blank line, insert:

```ruby
  Tinkerex::MailSettings.validate!

```

and extend the header comment's last sentence so the comment is true: after `read at delivery time.`
add ` validate! runs first: SMTP without APP_HOST would send links nobody can follow, so it is
refused here rather than discovered in an inbox.`

- [ ] **Step 5: Run, expect green**

Same command. Expected: all tests in the file pass (the existing four plus the two new).

- [ ] **Step 6: Mutation-check, then restore**

1. In `validate!`, delete the `return nil if env["APP_HOST"]…` line → the "with a host … passes" assertion must fail. Restore.
2. Delete the `return nil unless configured?(env)` line → the `validate!({})` assertion must fail. Restore.
3. Delete the `Tinkerex::MailSettings.validate!` line from the initializer → the initializer test must fail. Restore.

Report the actual output of each.

- [ ] **Step 7: Commit**

```sh
git add lib/tinkerex/mail_settings.rb config/initializers/mail.rb test/lib/mail_settings_test.rb
git commit -F - <<'MSG'
APP_HOST is required only with SMTP, and refused at boot without it

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 3: the share guard names the mount when `/library` is missing

**Files:**
- Modify: `lib/library_backend_check.rb:184-187`
- Test: `test/lib/library_backend_check_test.rb:19-27` (extend the existing test)

- [ ] **Step 1: Extend the failing test**

In the test that currently asserts `/does not exist/` (around line 24), add after that assertion:

```ruby
    assert_match(%r{:/library}, err.message,
                 "a stranger's container is the common case: the message must say how the folder " \
                 "is mounted (-v …:/library, or LIBRARY_HOST_PATH with the compose file)")
    assert_includes err.message, "LIBRARY_HOST_PATH"
```

- [ ] **Step 2: Run, expect the new assertion to fail**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/lib/library_backend_check_test.rb`
Expected: 1 failure on the `:/library` match.

- [ ] **Step 3: Change the message**

Replace lines 184-187 of `lib/library_backend_check.rb`:

```ruby
    unless File.exist?(path)
      # THE COMMON CASE IS A CONTAINER WITH NOTHING MOUNTED AT /library (I, 2026-10-14): the image
      # defaults LIBRARY_PATH to /library, so a bare `docker run` with no -v lands here. It must keep
      # REFUSING -- an unmounted /library inside the container would take uploads into the container's
      # own filesystem, which reads as data loss on the next recreate -- and say how the mount is made.
      raise Error, "LIBRARY_PATH #{path.inspect} does not exist — the library folder is not mounted " \
                   "there. With the compose file, LIBRARY_HOST_PATH in .env names the folder bound " \
                   "to /library (default: ./library beside the compose file); with docker run, " \
                   "-v /path/to/your/files:/library. Outside a container, check the path is spelled " \
                   "correctly and that the mount point has been created"
    end
```

- [ ] **Step 4: Run, expect green**

Same command; every test in the file passes.

- [ ] **Step 5: Mutation-check**

Remove the sentence from `With the compose file` through `:/library.` → the `:/library` and
`LIBRARY_HOST_PATH` assertions must fail. Restore; report the output.

- [ ] **Step 6: Commit**

```sh
git add lib/library_backend_check.rb test/lib/library_backend_check_test.rb
git commit -F - <<'MSG'
The share guard says how /library is mounted when nothing is there

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 4: the image defaults to share, starts as root, and the entrypoint drops to PUID:PGID

**Files:**
- Modify: `Dockerfile` (top comment lines 4-6; the `USER` block at 174-176; the F3D comment at
  205-210; new `ENV` after `ENV F3D_BIN`)
- Modify: `bin/docker-entrypoint` (rewrite)
- Create: `test/docker_entrypoint_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# test/docker_entrypoint_test.rb
require "test_helper"
require "tmpdir"
require "open3"

# bin/docker-entrypoint is bash and nothing in bin/ci runs the image, so the one way to pin what it
# does is to run the script with the three commands it delegates to replaced by recorders on PATH:
# `id` (root or not), `setpriv` (records its arguments, then runs the rest so the unprivileged half
# executes too) and `chown`. The directories are REAL temp directories owned by this process, so the
# "owner differs from PUID:PGID" decision is the real one, in both directions. The root-owned
# empty-library branch needs a root-owned directory and is proved by the Linux run the design
# records (spec §6), not here. The Dockerfile pins at the end are the other half of the same change.
class DockerEntrypointTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/docker-entrypoint")

  setup do
    @root = Dir.mktmpdir("entrypoint")
    %w[bin storage tmp log stubs library].each { |d| FileUtils.mkdir_p(File.join(@root, d)) }
    @entrypoint = File.join(@root, "bin/docker-entrypoint")
    FileUtils.cp(SCRIPT, @entrypoint)
    FileUtils.chmod(0o755, @entrypoint)
    @log = File.join(@root, "calls.log")
    stub("id", %(echo "${ENTRYPOINT_TEST_UID:-0}"))
    stub("chown", %(echo "chown $*" >> "$ENTRYPOINT_LOG"))
    # The real setpriv re-runs the script as a non-root uid; the stub records its arguments, then
    # makes the re-run see a non-root `id -u` (or the script would loop forever) and execs the rest.
    stub("setpriv", %(echo "setpriv $*" >> "$ENTRYPOINT_LOG"; export ENTRYPOINT_TEST_UID=1000; while [ "${1#--}" != "$1" ]; do shift; done; exec "$@"))
    stub("rails", %(echo "rails $*" >> "$ENTRYPOINT_LOG"), dir: "bin")
  end

  teardown { FileUtils.remove_entry(@root) }

  def stub(name, body, dir: "stubs")
    path = File.join(@root, dir, name)
    File.write(path, "#!/bin/bash\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  def run_entrypoint(*cmd, env: {})
    full_env = { "PATH" => "#{File.join(@root, 'stubs')}:#{ENV['PATH']}", "ENTRYPOINT_LOG" => @log,
                 "LIBRARY_PATH" => File.join(@root, "library"), "PUID" => nil, "PGID" => nil }.merge(env)
    out, status = Open3.capture2e(full_env, @entrypoint, *cmd, chdir: @root)
    [ out, status, File.exist?(@log) ? File.readlines(@log, chomp: true) : [] ]
  end

  test "as root: the app's directories become PUID:PGID, the library is left alone, setpriv re-runs the script" do
    out, status, calls = run_entrypoint("./bin/rails", "server", env: { "PUID" => "99", "PGID" => "100" })
    assert status.success?, out
    chowns = calls.grep(/\Achown /)
    ours = chowns.select { |c| c.include?(@root) }
    assert_equal 3, ours.size, "storage, tmp and log: #{calls}"
    ours.each { |c| assert_match(%r{\Achown -R 99:100 #{Regexp.escape(@root)}/(storage|tmp|log)\z}, c) }
    assert_empty chowns - ours - [ "chown -R 99:100 /home/rails" ],
                 "the only directory outside the app root it may chown is /home/rails: #{calls}"
    assert_empty calls.grep(/library/), "the library folder is the user's, never chowned: #{calls}"
    assert_includes calls, "setpriv --reuid=99 --regid=100 --clear-groups #{@entrypoint} ./bin/rails server"
    assert_equal [ "rails db:prepare", "rails server" ], calls.grep(/\Arails /),
                 "the unprivileged half prepares the database, then runs the server"
  end

  test "directories already owned by PUID:PGID are not chowned, and db:prepare runs only for the server" do
    out, status, calls = run_entrypoint("echo", "hi", env: { "PUID" => Process.uid.to_s, "PGID" => Process.gid.to_s })
    assert status.success?, out
    assert_empty calls.grep(/\Achown /), "owner already matches: #{calls}"
    assert_equal 1, calls.grep(/\Asetpriv /).size
    assert_empty calls.grep(/\Arails /)
    assert_equal "hi", out.strip
  end

  test "not root (started with --user): no chown, no setpriv, the command runs as given" do
    out, status, calls = run_entrypoint("echo", "hi", env: { "ENTRYPOINT_TEST_UID" => "501", "PUID" => "99" })
    assert status.success?, out
    assert_equal "hi", out.strip
    assert_empty calls
  end

  test "a PUID that is not a whole number is refused before anything is touched" do
    out, status, calls = run_entrypoint("echo", "hi", env: { "PUID" => "rails" })
    assert_not status.success?
    assert_includes out, "PUID"
    assert_empty calls
  end

  test "the image has no USER line and defaults to the share backend at /library" do
    dockerfile = Rails.root.join("Dockerfile").read
    assert_no_match(/^USER /, dockerfile, "the entrypoint chooses the user at run time")
    assert_match(/^ENV LIBRARY_BACKEND="share"/, dockerfile)
    assert_match(/LIBRARY_PATH="\/library"/, dockerfile)
    assert_includes dockerfile, 'ENTRYPOINT ["/rails/bin/docker-entrypoint"]'
  end
end
```

- [ ] **Step 2: Run, expect failures**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/docker_entrypoint_test.rb`
Expected: the first two tests fail (no setpriv call recorded), the fourth fails (exit 0), the
fifth fails (`USER 1000:1000` present). The third passes already.

- [ ] **Step 3: Rewrite the entrypoint**

```bash
#!/bin/bash -e

# THE ENTRYPOINT DROPS PRIVILEGES ITSELF (I, 2026-10-14). The image has no USER line, so a container
# starts as root; this script makes the app's own writable directories the requested user's and
# re-executes itself as PUID:PGID (default 1000:1000) through setpriv, which util-linux ships in the
# base image. A build-time USER cannot take an env value, and it is what forced every install to
# chown its folder to uid 1000.
#
# THE LIBRARY FOLDER IS NEVER CHOWNED. It is the user's, and the boot probes it instead
# (lib/library_backend_check.rb). One narrow exception: an EMPTY folder OWNED BY ROOT is one Docker
# auto-created for a missing bind-mount source, and it becomes the app user's so the first boot on
# Linux does not refuse its own default. A folder with anything in it, or owned by anyone else, is
# only probed.
#
# Started with --user (a `user:` line in compose) the script is not root, cannot chown or setpriv,
# and runs the command as given: the behaviour the image had before this script existed.
#
# `docker compose exec web bin/docker-entrypoint <cmd>` runs <cmd> as the same user as the server.
# A bare `docker exec` runs as root, and a task that creates files would leave them root-owned.

app_root="$(cd "$(dirname "$0")/.." && pwd)"

owned_by() { [ -n "$(find "$1" -maxdepth 0 -user "$2" -group "$3" 2>/dev/null)" ]; }

if [ "$(id -u)" = "0" ]; then
  PUID="${PUID:-1000}"
  PGID="${PGID:-1000}"
  case "$PUID$PGID" in
    *[!0-9]*) echo "PUID and PGID must be whole numbers (got PUID=$PUID PGID=$PGID)" >&2; exit 1 ;;
  esac

  for dir in "$app_root/storage" "$app_root/tmp" "$app_root/log" /home/rails; do
    [ -d "$dir" ] || continue
    owned_by "$dir" "$PUID" "$PGID" || chown -R "$PUID:$PGID" "$dir"
  done

  library="${LIBRARY_PATH:-/library}"
  if [ -d "$library" ] && [ -n "$(find "$library" -maxdepth 0 -user 0 2>/dev/null)" ] && [ -z "$(ls -A "$library")" ]; then
    chown "$PUID:$PGID" "$library"
  fi

  export HOME=/home/rails
  exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups "$0" "$@"
fi

# Unprivileged from here. If running the rails server then create or migrate existing database.
if [ "${@: -2:1}" == "./bin/rails" ] && [ "${@: -1:1}" == "server" ]; then
  ./bin/rails db:prepare
fi

exec "${@}"
```

- [ ] **Step 4: Edit the Dockerfile**

(a) Lines 4-6, the stale run instructions, become:

```
# This Dockerfile is designed for production, not development. docker-compose.yml is how it is run;
# by hand: docker build -t tinkerex . && docker run -d -p 8080:80 -v /path/to/files:/library \
#   -v tinkerex_storage:/rails/storage --name tinkerex tinkerex
```

(b) Lines 174-176 (the `USER` block) become:

```
# THE APP USER IS CHOSEN AT RUN TIME, NOT HERE (I, 2026-10-14). `rails` (1000:1000) is still created
# and still owns the copied tree, but there is NO `USER` line: the container starts as root and
# bin/docker-entrypoint drops to PUID:PGID (default 1000:1000) with setpriv after making the app's
# own writable directories that user's. A build-time USER cannot take an env value, and it is what
# forced every install to chown its folder to uid 1000. Started with --user, the entrypoint finds
# itself non-root and runs as given, which is what a `user:` line in compose still means.
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
```

(c) The F3D comment (currently "F3D_BIN RATHER THAN A PATH SYMLINK: … would need root back.")
becomes:

```
# F3D_BIN RATHER THAN A PATH SYMLINK: the renderer already reads ENV["F3D_BIN"], and F3D's own
# bin/../lib layout must stay intact — the binary resolves its bundled libraries and its OCCT plugin
# relative to itself, so it must NOT be lifted out of the tree the way the static binaries above are.
```

(d) After `ENV F3D_BIN="/opt/f3d/bin/f3d"` add:

```

# THE SHARE BACKEND AT /library IS THE IMAGE'S DEFAULT (I, 2026-10-14). A container started with no
# LIBRARY_BACKEND at all indexes whatever is mounted at /library, and the share guard refuses a boot
# with nothing mounted there (lib/library_backend_check.rb). The production guard that refuses a
# BLANK value still fires on an explicit `LIBRARY_BACKEND=`, the shape of a misconfigured
# destination. Every Kamal destination and both compose overlays set the backend explicitly.
ENV LIBRARY_BACKEND="share" \
    LIBRARY_PATH="/library"
```

- [ ] **Step 5: Run, expect green**

Same command; 5 passes. (`find -maxdepth 0 -user N -group N` takes numeric ids on both GNU and
BSD find, so the test runs on the Mac and on the Linux runners.)

- [ ] **Step 6: Build the image and run the root path for real**

```sh
docker build -t tinkerex:entrypoint-check . 2>&1 | tail -2
d=$(mktemp -d); mkdir "$d/lib"
docker run --rm -e PUID=4242 -e PGID=4242 -v "$d/lib:/library" tinkerex:entrypoint-check \
  sh -c 'id -u; id -g; stat -c "%u:%g" /rails/storage /rails/tmp /home/rails; echo "$HOME"; touch /rails/storage/probe && echo writable'
docker run --rm tinkerex:entrypoint-check sh -c 'id -u'
docker run --rm --user 1000:1000 tinkerex:entrypoint-check sh -c 'id -u'
```

Expected: `4242`, `4242`, three lines `4242:4242`, `/home/rails`, `writable`; then `1000` (the
default); then `1000` (the `--user` path). Report the actual output. Remove the image afterwards
(`docker rmi tinkerex:entrypoint-check`). On an Apple-silicon Mac the build is arm64 and that is fine.

- [ ] **Step 7: Mutation-check, then restore**

1. Replace `owned_by "$dir" "$PUID" "$PGID" ||` with nothing (always chown) → "already owned … not chowned" must fail. Restore.
2. Remove the `[ -z "$(ls -A "$library")" ]` condition and the root check so the library is chowned whenever it is a directory → "never chowned" must fail. Restore.
3. Change `--clear-groups` to `--init-groups` → the setpriv assertion must fail. Restore.
4. Put `USER 1000:1000` back in the Dockerfile → the Dockerfile test must fail. Restore.

Report actual output for each.

- [ ] **Step 8: Commit**

```sh
git add Dockerfile bin/docker-entrypoint test/docker_entrypoint_test.rb
git commit -F - <<'MSG'
The image defaults to share at /library, starts as root, and the entrypoint drops to PUID:PGID

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 5: the compose file pulls four images; the build overlay; the compose hygiene test

**Files:**
- Modify: `docker-compose.yml` (replace whole file)
- Create: `docker-compose.build.yml`
- Create: `test/compose_hygiene_test.rb`
- Modify: `test/install_docs_test.rb:69` (add the overlay to the scanned list)

- [ ] **Step 1: Write the failing test**

```ruby
# test/compose_hygiene_test.rb
require "test_helper"
require "yaml"

# THE QUICK START PULLS AND NEEDS NOTHING SET (I, 2026-10-14). These pins hold the compose file to
# that: a `build:` creeping back makes `docker compose up` compile for minutes instead of pulling
# (with image: and build: both present, compose BUILDS when the image is not in the local cache), a
# required env_file makes a missing .env a boot error, a lost platform pin fails openscad on every
# arm64 machine, and a profile hides the Tools gallery again. YAML-parsed, never grepped, so a
# comment can neither satisfy nor trip them.
class ComposeHygieneTest < ActiveSupport::TestCase
  SERVICES = %w[web boxes openscad addons].freeze

  def compose(file) = YAML.safe_load(Rails.root.join(file).read, aliases: true)

  test "the quick start pulls four ghcr images, behind no profile, and builds nothing" do
    services = compose("docker-compose.yml").fetch("services")
    assert_equal SERVICES.sort, services.keys.sort
    services.each do |name, s|
      assert_nil s["build"], "#{name} has a build: — compose would build instead of pulling"
      assert_nil s["profiles"], "#{name} is behind a profile; the Tools gallery ships on by default"
      assert_match(%r{\A(\$\{TINKEREX_IMAGE:-)?ghcr\.io/chaim354/[a-z-]+:latest\}?\z}, s.fetch("image"), name)
    end
  end

  test "the app needs no .env, carries the Tools URLs and the thread count, and keeps its two mounts" do
    web = compose("docker-compose.yml").dig("services", "web")
    assert_equal [ { "path" => ".env", "required" => false } ], web["env_file"]
    env = web.fetch("environment")
    assert_equal "http://boxes:8000", env["BOXES_SIDECAR_URL"]
    assert_equal "http://openscad:8000", env["OPENSCAD_SIDECAR_URL"]
    assert_equal "http://addons", env["ADDON_SOURCE_URL"]
    assert_equal "${RAILS_MAX_THREADS:-16}", env["RAILS_MAX_THREADS"], "Puma's stock 3 starves once a sidecar is proxied"
    assert_equal "${PUID:-1000}", env["PUID"]
    assert_equal "${PGID:-1000}", env["PGID"]
    assert_not_includes env.keys, "LIBRARY_BACKEND", "the backend is the image's default now (Dockerfile)"
    assert_not_includes env.keys, "LIBRARY_PATH"
    assert_equal [ "tinkerex_storage:/rails/storage", "${LIBRARY_HOST_PATH:-./library}:/library" ], web["volumes"]
    assert_equal [ "${TINKEREX_PORT:-8080}:80" ], web["ports"]
  end

  test "openscad, the one x86-only image, is pinned to amd64" do
    assert_equal "linux/amd64", compose("docker-compose.yml").dig("services", "openscad", "platform")
  end

  test "the build overlay restores a build for every service under a :local name" do
    services = compose("docker-compose.build.yml").fetch("services")
    assert_equal SERVICES.sort, services.keys.sort
    services.each do |name, s|
      assert s["build"].present?, "#{name} must build in the overlay"
      assert_match(/:local\z/, s.fetch("image"), "#{name}'s built image must not shadow the ghcr tag")
    end
  end
end
```

- [ ] **Step 2: Run, expect failures**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/compose_hygiene_test.rb`
Expected: tests 1, 2 and 4 fail (build present, env_file a string, overlay missing); 3 fails
(no platform).

- [ ] **Step 3: Replace `docker-compose.yml`**

```yaml
# Tinkerex with the Tools gallery: four containers, your files in a folder beside this file. Nothing
# to set before the first start. docs/INSTALL.md is the guide and names every override.
#
#   docker compose up -d                           pull and start; then http://localhost:8080
#   docker compose pull && docker compose up -d    update
#
# Overrides go in an optional .env beside this file: LIBRARY_HOST_PATH to use an existing folder,
# PUID/PGID to run as a particular user on Linux, TINKEREX_PORT, and the accounts/mail knobs
# (.env.example lists them). docker-compose.build.yml rebuilds all four images from a clone instead
# of pulling them; docker-compose.chunk_remote.yml adds the sync server (INSTALL.md section 5).

services:
  web:
    image: ${TINKEREX_IMAGE:-ghcr.io/chaim354/tinkerex:latest}
    ports:
      - "${TINKEREX_PORT:-8080}:80"
    env_file:
      - path: .env
        required: false
    environment:
      # The user the app runs as inside the container; files it writes into your folder are owned
      # by it. Docker Desktop (Mac, Windows) needs nothing here; on Linux match your folder's owner.
      PUID: ${PUID:-1000}
      PGID: ${PGID:-1000}
      # Puma's stock 3 threads starve once a tool call is proxied through the app; 16 is what the
      # author runs.
      RAILS_MAX_THREADS: ${RAILS_MAX_THREADS:-16}
      # The Tools gallery, wired to the three services below.
      BOXES_SIDECAR_URL: http://boxes:8000
      OPENSCAD_SIDECAR_URL: http://openscad:8000
      ADDON_SOURCE_URL: http://addons
    volumes:
      - tinkerex_storage:/rails/storage
      - ${LIBRARY_HOST_PATH:-./library}:/library
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost/up"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 90s
    restart: unless-stopped

  # The Tools gallery. The two sidecars are GPL-licensed and run as their own processes, reached
  # over HTTP and never linked into the app (CLAUDE.md section 9); addons serves the bundle files.
  boxes:
    image: ghcr.io/chaim354/boxes-sidecar:latest
    restart: unless-stopped
  openscad:
    image: ghcr.io/chaim354/openscad-sidecar:latest
    # x86-only (an AppImage): the pin makes an arm64 Docker Desktop pull and emulate it instead of
    # failing with "no matching manifest". An arm64 Linux box without emulation loses this one
    # service and keeps the other three; the OpenSCAD card then shows as unavailable.
    platform: linux/amd64
    volumes:
      - openscad_cache:/cache
    restart: unless-stopped
  addons:
    image: ghcr.io/chaim354/tinkerex-addons:latest
    restart: unless-stopped

volumes:
  tinkerex_storage: {}
  openscad_cache: {}
```

- [ ] **Step 4: Create `docker-compose.build.yml`**

```yaml
# Build every image from source instead of pulling it: a clone of this repository plus a sibling
# checkout of chaim354/tinkerex-addons (TINKEREX_ADDONS_PATH, default ../tinkerex-addons). For an
# arm64 Linux box, a machine without registry access, or working on the app:
#
#   docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
#
# The openscad image is x86-only and cannot be built on arm64; start the other three by name there
# (… up -d --build web boxes addons). The :local names keep a built image from shadowing the ghcr tag.
services:
  web:
    image: tinkerex:local
    build: .
  boxes:
    image: boxes-sidecar:local
    build: sidecar/boxes
  openscad:
    image: openscad-sidecar:local
    build: sidecar/openscad
  addons:
    image: tinkerex-addons:local
    build: ${TINKEREX_ADDONS_PATH:-../tinkerex-addons}
```

- [ ] **Step 5: Add the overlay to the install-docs scan**

In `test/install_docs_test.rb`, line 69, the list becomes:

```ruby
    %w[docker-compose.yml docker-compose.build.yml docker-compose.chunk_remote.yml .env.example].each do |file|
```

- [ ] **Step 6: Validate the files with Compose itself and run the tests**

```sh
docker compose -f docker-compose.yml config --quiet && echo base-ok
docker compose -f docker-compose.yml -f docker-compose.build.yml config --quiet && echo build-ok
docker compose -f docker-compose.yml -f docker-compose.chunk_remote.yml config --quiet 2>&1 | tail -1
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/compose_hygiene_test.rb
```

Expected: `base-ok`, `build-ok`, the sync overlay prints one line about a missing required value
(its `${SYNC_PUBLIC_URL:?…}` — that is the overlay's existing contract, unchanged), and 4 passes.
`test/install_docs_test.rb` will fail on `PUID`/`PGID` until Task 6 adds their rows; that is
expected and is noted in the report.

- [ ] **Step 7: Mutation-check, then restore**

1. Add `build: .` under `web` in the base file → test 1 must fail. Restore.
2. Change `required: false` to `required: true` → test 2 must fail. Restore.
3. Delete the `platform:` line → test 3 must fail. Restore.

Report actual output for each.

- [ ] **Step 8: Commit**

```sh
git add docker-compose.yml docker-compose.build.yml test/compose_hygiene_test.rb test/install_docs_test.rb
git commit -F - <<'MSG'
One compose file pulls the app and the Tools gallery; building moves to an overlay

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 6: the guide, the README, the env example, the handoff note

**Files:**
- Modify: `README.md` (Status, Quick start, First run, Where files come from, The Tools gallery, Updating)
- Modify: `docs/INSTALL.md` (intro, sections 1–3 rewritten; edits in 4, 6, 7, 8)
- Modify: `.env.example` (rewrite)
- Modify: `docs/superpowers/plans/2026-10-14-i-install-and-onboarding-handoff.md` (one paragraph under §2)
- Test: `test/install_docs_test.rb` (existing; must pass once this task and Task 5 are both in)

Section numbers in INSTALL.md stay 1–10: sections 4, 5, 8 and 9 are cited by number from the app
(`users/registrations/closed.html.erb`, the env comments) and from each other.

- [ ] **Step 1: README.md**

Replace from `## Status` through the end of `## Updating and backups` with:

````markdown
## Status

It runs on real hardware, every day, for its author. There are three ways to hold the files, chosen
per deployment: a **folder you point it at** (a NAS share, a directory on the box), **your own S3
bucket**, or the **sync server** (`chaim354/tinkerex-sync`), which adds per-account libraries,
versions and restore, and is what the desktop client syncs against. The first two keep your files as
plain files you can edit with anything else. It is open source under the Apache License 2.0, and the
images are published on ghcr.io under `chaim354`.

## Quick start

You need Docker: Docker Desktop on a Mac or Windows machine, or Docker Engine with the Compose
plugin on Linux. Make a folder, download [`docker-compose.yml`](docker-compose.yml) into it, and in
that folder:

```sh
docker compose up -d
```

Open `http://localhost:8080`. Nothing to generate, edit or chown first; the full guide, with every
setting you can change, is **[`docs/INSTALL.md`](docs/INSTALL.md)**.

## First run

The first account you create is the owner: it is confirmed on the spot, without a mail server, and
sign-ups close behind it. Later accounts come from the console or from opening registration, both in
the guide. A `library/` folder has appeared beside the compose file: that is your library. To use a
folder you already have, put `LIBRARY_HOST_PATH=/path/to/files` in a `.env` file beside the compose
file and run `docker compose up -d` again.

## Where files come from

The folder you pointed it at. It is indexed on start, every 15 minutes, and on the Rescan button;
uploads in the browser land in it as ordinary files; deletions move files to a `.trash/` folder inside
it; folders under `Projects/` become projects. The app is a view of the folder, not a copy of it.

## The Tools gallery

Add-ons — a box generator and an OpenSCAD editor — are the other three containers the compose file
starts, so the gallery is live from the first start. They run as separate processes reached over
HTTP (the two tools are GPL-licensed and are never linked into the app).

## Updating and backups

Update with `docker compose pull && docker compose up -d`; the database migrates on start. Back up
the `tinkerex_storage` volume's database with SQLite's `.backup` (never copy the live file) and your
folder with anything. Both recipes are in the guide.
````

- [ ] **Step 2: INSTALL.md — the intro and sections 1–3**

Replace from the top of the file through the end of the "Your own S3 bucket instead of a folder"
subsection (everything before `## 3. The Tools gallery (optional)`), AND delete the old section 3
entirely, with the text below. The new section 3 is the settings section; the Tools gallery moves
into section 2.

````markdown
# Installing Tinkerex

A self-hosted library for a maker's files, run with Docker Compose on your own machine — a Mac, a
Windows machine or a Linux box. This page is the whole of what a new install needs: the quick start,
the settings you can change, the optional pieces, and — in section 8 — **the reference for every
environment variable the app reads**. That table is guarded by `test/install_docs_test.rb`, which
fails the build when the code reads a variable this page does not name, so it is current by
construction rather than by promise.

The first path here is the **`share` backend**: your files stay plain files in a folder, the app
indexes them, and that folder stays yours — editable with anything else. The sync server (section 5)
is the second path. Pointing the app at your own S3 bucket is a third, at the end of section 3.

## 1. What you need

- **Docker.** On a Mac or a Windows machine, [Docker Desktop](https://www.docker.com/products/docker-desktop/).
  On Linux, Docker Engine with the Compose plugin. Either way `docker compose version` must say
  2.24 or newer.
- **A folder for your files**, or nothing: the first start makes an empty `library/` folder beside
  the compose file, and you can point it at an existing folder afterwards (section 3).
- Nothing else: no Ruby, no database server, no mail server, no secrets to generate. The database is
  SQLite in a Docker volume, and the session secret is generated on the first start and kept there.

Four images are pulled: the app, the two tools (a box generator and OpenSCAD) and the small server
that holds the tool bundles. The app image is built for amd64 and arm64, so an Apple-silicon Mac or a
Raspberry Pi-class box runs it natively; STEP, IGES, OBJ and the other mesh formats get a generic
icon instead of a thumbnail on arm64 (F3D ships no Linux arm64 build; STL, SVG, DXF, LightBurn, PDF,
images and Gerber all render). The OpenSCAD image is x86-only; Docker Desktop runs it under
emulation, and section 3 has the note for an arm64 Linux box.

## 2. Quick start

Make a folder, put [`docker-compose.yml`](../docker-compose.yml) in it (download it from this
repository), and in that folder:

```sh
docker compose up -d
docker compose logs -f web      # until Puma reports it is listening; Ctrl-C leaves it running
```

The first start pulls the four images. `curl http://localhost:8080/up` answers `200` once the app is
ready; the compose healthcheck polls the same path. Open `http://localhost:8080`.

**If a container exits**, `docker compose logs web` has the reason, and it is one sentence naming the
problem. The app refuses to boot on a misconfiguration rather than starting and failing later.

### First run: the first account is the owner

With no account yet, the sign-up page works and says so: *"This is the server's first account. It
becomes the owner and needs no email confirmation."* Create it; you are signed in. **After that,
sign-ups are closed** — the page answers "Sign-ups are closed" and the link disappears — until you
either open them (`REGISTRATION`, section 4) or add accounts from the console (also section 4).
No mail server is involved in any of this.

### Where your files come from

- **The `library/` folder beside the compose file is your library** — or the folder you name in
  section 3. It is indexed on start, every 15 minutes after that, and whenever you press
  **Rescan library** on the Files page. Anything you put in the folder by other means — a copy
  over the network, a slicer saving into it — appears on the next scan.
- **Uploads in the browser land in the folder** as ordinary files, so the folder remains the
  truth and the app a view of it.
- **Deleting in the app moves the file to `.trash/`** inside the folder (keyed by an id, so two
  deletes of the same name never collide), and empties entries older than `LIBRARY_TRASH_DAYS`
  (30 days) once a day. Restore is on the Trash page.
- **Folders under `Projects/` become projects**: a folder dropped directly under `Projects/` is
  discovered on the next sweep (every 15 minutes) and gets a project page with its files attached;
  loose files at a project folder's root are filed into category sub-folders.
- **Thumbnails** are rendered in the background after a scan; a large library takes a while to
  fill in. They live in the `tinkerex_storage` volume, not in your folder.
- A rename on disk keeps the file's identity (its attachments, tags and project links) as long as
  the content is unchanged; a scan that would remove more than `LIBRARY_SCAN_MAX_DELETE_PCT` (20%)
  of the library at once is refused and logged, because that is what an unmounted share looks like.

### The Tools gallery

Tools are add-ons that run inside the app and save their output into your library — a box generator
and an OpenSCAD editor are the two that exist. They are the other three containers the compose file
starts, so the gallery is live from the first start. The two tool images are GPL-licensed, which is
why they are separate processes talked to over HTTP and never linked into the app. On an arm64 Linux
box without x86 emulation the OpenSCAD container cannot start; the other three come up, and that one
card shows as unavailable.

## 3. Settings: your folder, your user, your port

Everything here is optional. A setting goes in a file named `.env` beside the compose file, one
`NAME=value` per line, followed by `docker compose up -d` again; `.env.example` in the repository
lists every line with its default.

- **`LIBRARY_HOST_PATH`** — the folder that holds your files, instead of `./library`. An absolute
  path (`/mnt/user/files`, `/Users/you/Workshop`, `C:\Users\you\Workshop`) or one relative to the
  compose file. On a Mac or Windows the folder must be under a location Docker Desktop shares with
  containers, which by default includes your home directory. The app is a view of that folder, not
  a copy: uploads land in it, deleted files move to its `.trash/`, and anything another program
  puts there is indexed within 15 minutes.
- **`PUID` and `PGID`** (Linux) — the user and group the app runs as inside the container, default
  `1000`. Files the app writes into your folder are owned by that user, and the boot checks it can
  write there. Set them to the owner of your folder (`id -u` and `id -g` print yours); on Unraid,
  `99` and `100`. Docker Desktop on Mac and Windows presents your folders as writable by any user,
  so there is nothing to set there. The app never changes your folder's ownership — it only probes
  it — with one exception: a brand-new, empty folder that Docker itself created on Linux (which
  would be root's) is made the app user's, so the default works on the first start.
- **`TINKEREX_PORT`** — the port on this machine, default `8080`.
- Accounts and mail are section 4; the sync server is section 5; every other variable is in
  section 8.

### Building from source instead of pulling

With a clone of this repository and a sibling checkout of `chaim354/tinkerex-addons` at
`../tinkerex-addons` (or `TINKEREX_ADDONS_PATH`), the overlay `docker-compose.build.yml` builds all
four images on this machine:

```sh
git clone https://github.com/chaim354/tinkerex.git && git clone https://github.com/chaim354/tinkerex-addons.git
cd tinkerex
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

The first build downloads a few hundred megabytes of renderers and compiles two small Rust tools;
allow several minutes. It is the path for an arm64 Linux box (the OpenSCAD image cannot be built
there — start the other three by name: `… up -d --build web boxes addons`), for a machine without
registry access, and for working on the app.

### Your own S3 bucket instead of a folder

The `s3` backend indexes an S3-compatible bucket (SeaweedFS, MinIO, R2, AWS) the same way: the
object is the truth, no versions, current state only. There is no template for it; the recipe is a
small overlay, because the image defaults to the share backend and `docker-compose.yml` binds the
`/library` folder. Save this as `docker-compose.s3.yml`, put the five `LIBRARY_S3_*` values in
`.env`, and start with `-f docker-compose.yml -f docker-compose.s3.yml`:

```yaml
services:
  web:
    environment:
      LIBRARY_BACKEND: s3
      LIBRARY_PATH: ""
    volumes: !override
      - tinkerex_storage:/rails/storage
```

`LIBRARY_S3_BUCKET`, `LIBRARY_S3_ACCESS_KEY_ID` and `LIBRARY_S3_SECRET_ACCESS_KEY` are required;
`LIBRARY_S3_ENDPOINT` for anything that is not AWS; `LIBRARY_S3_PREFIX` to use one folder of the
bucket. The boot checks that they are present and nothing more — a wrong credential surfaces on
first use, never as a crash loop.
````

- [ ] **Step 3: INSTALL.md — section 4 edits**

In the **Mail.** paragraph, directly after the sentence that ends `tells a visitor that the server
cannot send email yet.`, insert this sentence (markdown, verbatim):

```markdown
**`APP_HOST`** — the host name or address people reach this server at, with no scheme (`maker.example.net`, `192.168.1.20`) — is required as soon as `SMTP_ADDRESS` is set, and the boot refuses the pair without it: it is what the links in mail point at. Without mail it need not be set.
```

Replace the two `docker compose exec` lines in the **Adding an account without mail** block with:

```sh
docker compose exec -e TINKEREX_PASSWORD web bin/docker-entrypoint bin/rails 'tinkerex:owner[someone@example.net]'
docker compose exec -e TINKEREX_PASSWORD web bin/docker-entrypoint bin/rails 'tinkerex:password[someone@example.net]'
```

and after that block's closing fence add this paragraph (markdown, verbatim):

```markdown
`bin/docker-entrypoint` in front of the command runs it as the same user the server runs as (`PUID`). A bare `docker compose exec` runs as root, and a task that creates files would leave them owned by root.
```

- [ ] **Step 4: INSTALL.md — section 5 edit**

The sync overlay still builds from a sibling checkout; its text stands. Only its last paragraph's
opener changes: `Then start with both files:` keeps its command, but add before it: `The sync
server image is not yet pulled by the overlay — it is built from the checkout — so this path still
needs the clone above.`

- [ ] **Step 5: INSTALL.md — section 6**

Replace the section body with:

````markdown
```sh
docker compose pull
docker compose up -d                # with the same -f overlay as before, if you use one,
                                    # or set COMPOSE_FILE in .env once
```

The database migrates itself when the container starts (the entrypoint runs `db:prepare` before
Puma). `.env` is yours and nothing here touches it; `.env.example` in the repository may gain lines
in a new release, so `diff` it against yours now and then. A library scan runs on start, so a file
that changed on disk while the app was down is picked up. Building from source instead: `git pull`
in the clone, then the overlay command from section 3 with `--build`.
````

- [ ] **Step 6: INSTALL.md — section 7**

In the first bullet, the phrase that today reads (markdown, verbatim):

```markdown
four SQLite files (`production.sqlite3` is the one that matters; the cache, queue and cable files are disposable) and the thumbnails.
```

becomes:

```markdown
four SQLite files (`production.sqlite3` is the one that matters; the cache, queue and cable files are disposable), the thumbnails, and `secret_key_base`, the session secret generated on the first start — a restored volume keeps everyone signed in, a lost one only signs everyone out.
```

Replace the three `docker compose exec web …` backup lines and the `previews:backfill_missing`
mention so each goes through the entrypoint:

```sh
docker compose exec web bin/docker-entrypoint sqlite3 /rails/storage/production.sqlite3 ".backup /rails/storage/backup.sqlite3"
docker compose cp web:/rails/storage/backup.sqlite3 "./tinkerex-$(date +%F).sqlite3"
docker compose exec web bin/docker-entrypoint rm /rails/storage/backup.sqlite3
```

and `docker compose exec web bin/docker-entrypoint bin/rails previews:backfill_missing`.

- [ ] **Step 7: INSTALL.md — section 8 rows**

Edit these rows (first cell unchanged where it exists; the other cells as shown):

| variable | required? | default | what it does |
|---|---|---|---|
| `SECRET_KEY_BASE` | no | generated on the first start, kept at `storage/secret_key_base` in the volume | Signs sessions and cookies. Set it to use your own (`openssl rand -hex 64`); a blank value counts as unset. Changing or losing it signs everyone out and nothing else. |
| `LIBRARY_BACKEND` | no (the image defaults to `share`) | `share` | Where the files live: `share` (a folder), `s3` (a bucket) or `chunk_remote` (the sync server). Chosen per deployment, never per user; the two overlays set it. An explicit blank refuses the boot. |
| `LIBRARY_PATH` | no | `/library` (the image default) | The folder inside the container to index. The boot checks that it exists, is a directory, and is writable by the app's user — by writing a probe file, because mode bits lie on network mounts. |
| `APP_HOST` | with `SMTP_ADDRESS` | `APP_HOST-IS-NOT-SET.invalid`, never rendered without mail | The host name (no scheme) that links in email point at; also the default HELO domain and the domain of the default sender. The boot refuses `SMTP_ADDRESS` without it. |
| `RAILS_MAX_THREADS` | no | 3 (Puma), 5 (database pool); **the compose file sets 16** | Puma's thread count and the SQLite connection pool. 3 starves once a tool call is proxied through the app; 16 is what the author runs. |

Add two rows after `LIBRARY_HOST_PATH` in the **Compose only** block (they are read by the
entrypoint, which compose passes them to):

| `PUID`, `PGID` | no | `1000`, `1000` | The user and group the app runs as inside the container, and so the owner of every file it writes into your folder (section 3). Linux: the folder's owner, or `99`/`100` on Unraid. Docker Desktop needs nothing. The container starts as root and drops to them; `--user` on the container skips that and runs as given. |

Edit these **Compose only** rows:

| `LIBRARY_HOST_PATH` | no | `./library` | The folder on the host bound to `/library`; a relative path is resolved against the compose file's directory. Section 3. |
| `TINKEREX_IMAGE` | no | `ghcr.io/chaim354/tinkerex:latest` | The app image. `docker-compose.build.yml` builds `tinkerex:local` from the checkout instead. |
| `TINKEREX_ADDONS_PATH` | build overlay | `../tinkerex-addons` | Path to a checkout of `chaim354/tinkerex-addons`, the build context for the addon bundle server in `docker-compose.build.yml`. |
| `COMPOSE_FILE` | no | — | Docker's own: `COMPOSE_FILE=docker-compose.yml:docker-compose.chunk_remote.yml` in `.env` saves typing `-f` on every command. |

(The `COMPOSE_PROFILES` half of that row goes: there is no profile any more.)

Edit the **Tools gallery** rows' "required?" cells: `ADDON_SOURCE_URL` → `*set by compose*`
(`http://addons`); `BOXES_SIDECAR_URL`, `OPENSCAD_SIDECAR_URL` → `*set by compose*`
(`http://boxes:8000`, `http://openscad:8000`).

- [ ] **Step 8: `.env.example` — replace the whole file**

```sh
# Tinkerex overrides for docker compose. NOTHING HERE IS REQUIRED: the compose file starts with every
# line at its default. To change one, copy this file to .env beside docker-compose.yml, uncomment the
# line, set it, and run docker compose up -d again. docs/INSTALL.md explains each one.
#
# docker compose reads .env twice: for the ${...} substitutions in docker-compose.yml, and as the
# web container's environment. Lines starting with # are ignored. Put a comment on its own line,
# never after a value.

# ---- Your files (docs/INSTALL.md section 3) ----
# The folder that holds your files, instead of ./library beside the compose file. Absolute, or
# relative to the compose file.
# LIBRARY_HOST_PATH=./library

# ---- Who the app runs as (Linux; Docker Desktop on Mac and Windows needs nothing) ----
# The user and group that own the files the app writes into your folder: the owner of that folder
# (id -u and id -g print yours), or 99 and 100 on Unraid.
# PUID=1000
# PGID=1000

# ---- The port on this machine ----
# TINKEREX_PORT=8080

# ---- Reached over HTTPS through a reverse proxy? Then set this; without TLS in front it locks you out.
# FORCE_SSL=1

# ---- Accounts and mail (docs/INSTALL.md section 4) ----
# closed (the default in production) means only the first account, the owner, can sign up. open is
# refused at boot on the share and s3 backends, where every account indexes the same library.
# REGISTRATION=closed
# Mail is off until SMTP_ADDRESS is set; the rest have the common defaults shown. APP_HOST is
# required with it: the host name or address people reach this server at, no scheme.
# SMTP_ADDRESS=
# APP_HOST=
# SMTP_PORT=587
# SMTP_USER_NAME=
# SMTP_PASSWORD=
# SMTP_DOMAIN=
# SMTP_AUTHENTICATION=plain
# SMTP_STARTTLS=true
# MAIL_FROM=
# A public demo: one click on the sign-in page signs visitors into the shared account named here,
# which is destroyed and re-seeded every night at 04:00 UTC. On share and s3 every account indexes
# the same library, so set it only on a server that holds nothing else. Create the account once with
#   docker compose exec web bin/docker-entrypoint bin/rails tinkerex:demo:setup
# DEMO_ACCOUNT_EMAIL=
# The largest single file the demo account may upload, in bytes (25 MB).
# DEMO_MAX_UPLOAD_BYTES=26214400

# ---- Days a deleted file stays in .trash/ before the daily purge (0 keeps everything forever) ----
# LIBRARY_TRASH_DAYS=30

# ---- The sync server (docs/INSTALL.md section 5; docker-compose.chunk_remote.yml) ----
# Built from a sibling checkout of chaim354/tinkerex-sync. COMPOSE_FILE saves typing the two -f
# flags on every command.
# TINKEREX_SYNC_PATH=../tinkerex-sync
# TINKEREX_SYNC_PORT=3001
# COMPOSE_FILE=docker-compose.yml:docker-compose.chunk_remote.yml
# The sync server's own session secret: openssl rand -hex 64
# SYNC_SECRET_KEY_BASE=
# Shared by the app and the sync server, one value: openssl rand -hex 32
# SYNC_ADMIN_TOKEN=
# The address your other devices reach the sync server at, scheme included: this host and
# TINKEREX_SYNC_PORT (e.g. http://192.168.1.10:3001), or a reverse proxy's name for that port.
# The desktop app is handed it when it signs in.
# SYNC_PUBLIC_URL=
# Encrypt each account's sync credential in the database: openssl rand -hex 16 each. Keep them
# with your backups; losing them makes every stored sync credential unreadable.
# ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=
# ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=
# ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=

# ---- Advanced ----
# Web server threads and the database pool; the compose file's 16 is what the author runs.
# RAILS_MAX_THREADS=16
# The session secret is generated on the first start and kept in the app's volume. Set this only to
# use your own (openssl rand -hex 64); a blank value counts as unset.
# SECRET_KEY_BASE=
# A different app image, e.g. a pinned tag. docker-compose.build.yml builds tinkerex:local instead.
# TINKEREX_IMAGE=ghcr.io/chaim354/tinkerex:latest
# Where a clone of chaim354/tinkerex-addons is, for docker-compose.build.yml.
# TINKEREX_ADDONS_PATH=../tinkerex-addons

# Never set RAILS_MASTER_KEY (docs/INSTALL.md section 9).
```

- [ ] **Step 9: the handoff note**

In `docs/superpowers/plans/2026-10-14-i-install-and-onboarding-handoff.md`, directly under the
heading `## 2. Install — what a stranger hits, in order`, insert:

```markdown
**Shipped by sub-project I (`docs/superpowers/specs/2026-10-14-i-simple-self-host-design.md`,
2026-10-14):** 2.1 (the compose file pulls four ghcr images and builds nothing; building is the
`docker-compose.build.yml` overlay), 2.2 (`PUID`/`PGID` and an entrypoint that drops privileges; the
library folder is never chowned), the Tools gallery on by default, Docker Desktop on Mac and Windows
as hosts, and zero required settings (the session secret is generated into the volume, the backend
and path are image defaults, `APP_HOST` is needed only with SMTP). Still the owner's: the four ghcr
packages' visibility. Still open: 2.3 (the sync overlay builds from a checkout) and 2.4 (the Unraid
template on a real box).
```

- [ ] **Step 10: Run the install-docs test (needs Task 5 merged or present) and read the guide once**

Run: `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/install_docs_test.rb test/docs_hygiene_test.rb`
Expected: green. If `PUID`/`PGID` are reported missing, the rows in Step 7 did not land in the
table's first cell as `` `PUID`, `PGID` `` — fix the row. Then read INSTALL.md top to bottom once
for a sentence that still says "build", "`--profile tools`", "chown", "`openssl rand`" as a first
step, or "env file … not found", and fix any you find: `grep -n -iE 'profile|chown|--build|openssl rand' docs/INSTALL.md README.md .env.example` lists the candidates; each hit must be one of the
sentences this task wrote on purpose.

- [ ] **Step 11: Commit**

```sh
git add README.md docs/INSTALL.md .env.example docs/superpowers/plans/2026-10-14-i-install-and-onboarding-handoff.md
git commit -F - <<'MSG'
The guide: one compose file, nothing to set, Docker Desktop on Mac and Windows

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 7: the Unraid template takes PUID/PGID and asks for nothing else

**Files:**
- Modify: `unraid/tinkerex.xml`

- [ ] **Step 1: Edit the template**

(a) Replace the XML comment's second paragraph (from `The container runs as uid 1000` through the
`A path the container cannot write…` sentence) with:

```
  The container runs as PUID:PGID, 99:100 by default here -- Unraid's own nobody:users -- so the
  appdata folder and the share need no chown: the entrypoint makes its own app-data folder that
  user's, and an Unraid share with the default permissions is writable by it already. A path the
  container cannot write refuses the boot with a message naming it.
```

(b) In `<Overview>`, replace `Both paths below must be writable by uid 1000 (see the template's
comment).` with `It runs as PUID:PGID, 99:100 by default (nobody:users), so uploads land on the share
owned the way your other files are.`

(c) The **App data** Config's `Description` becomes `Holds the SQLite databases, the thumbnails and
the session secret. Created on first start; nothing to prepare.`

(d) The **Library** Config's `Description`: replace `Must be writable by uid 1000; Unraid's default
share permissions allow it.` with `Writable by PUID:PGID; Unraid's default share permissions allow it.`

(e) After the Library Config add two Configs:

```xml
  <Config Name="PUID" Target="PUID" Default="99" Mode="" Description="The user the app runs as, and the owner of every file it writes into the share. 99 is Unraid's nobody." Type="Variable" Display="always" Required="true" Mask="false">99</Config>
  <Config Name="PGID" Target="PGID" Default="100" Mode="" Description="The group the app runs as. 100 is Unraid's users." Type="Variable" Display="always" Required="true" Mask="false">100</Config>
```

(f) The **SECRET_KEY_BASE** Config becomes `Display="advanced" Required="false"` with
`Description="Optional. Generated on the first start and kept in the app data folder; set it only to use your own (openssl rand -hex 64)."`.

(g) The **APP_HOST** Config becomes `Display="advanced" Required="false"` with
`Description="Only needed with SMTP_ADDRESS: the host name or IP people reach this server at, with no scheme (e.g. 192.168.1.20). Links in email point at it."`.

(h) The **SMTP_ADDRESS** description gains `, and APP_HOST with it` after `Empty means no mail`.

- [ ] **Step 2: Check it is well-formed and still names every variable the table documents**

```sh
xmllint --noout unraid/tinkerex.xml && echo well-formed
grep -o 'Target="[A-Z_]*"' unraid/tinkerex.xml | sort -u
```

Expected: `well-formed`, and the list now includes `PUID` and `PGID`. Every `Target` must have a row
in `docs/INSTALL.md` section 8 (Task 6 adds `PUID`/`PGID`); confirm by eye.

- [ ] **Step 3: Commit**

```sh
git add unraid/tinkerex.xml
git commit -F - <<'MSG'
The Unraid template runs as nobody:users and asks for no secret or host name

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 8: the published image is multi-arch

**Files:**
- Modify: `config/deploy.yml:219-225`

- [ ] **Step 1: Edit the builder block**

Replace lines 219-225 with:

```yaml
# Configure the image builder. Both target servers (Unraid + OVH) are amd64; the PUBLISHED image is
# multi-arch since I (2026-10-14) so that Docker Desktop on an Apple-silicon Mac, and a Pi-class
# box, pull a native arm64 half instead of emulating amd64. Kamal uses buildx on the Mac control
# machine: the arm64 half is the native build there and amd64 the QEMU-emulated one (the only one
# it built before, measured cold at ~84 s; expect roughly double now). Every Dockerfile stage is
# arch-neutral or picks by TARGETARCH, F3D leaving a README on arm64. Verify a push with
#   docker buildx imagetools inspect ghcr.io/chaim354/tinkerex:latest
# which must list linux/amd64 and linux/arm64. A fat build context kills this — keep client/, docs/,
# test/, .claude/ out via .dockerignore.
builder:
  arch:
    - amd64
    - arm64
```

- [ ] **Step 2: Prove Kamal parses it and the hygiene suite is unmoved**

```sh
bundle exec kamal config 2>&1 | grep -A3 'builder' | head -8
LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test test/deploy_hygiene_test.rb
```

Expected: the builder shows both arches (`kamal config` may need the secrets preflight; if it stops
at a secret, `bundle exec ruby -e 'require "kamal"; p Kamal::Configuration.create_from(config_file: Pathname("config/deploy.yml")).builder.arches'`
must print `["amd64", "arm64"]`), and the hygiene test is green.

- [ ] **Step 3: Commit**

```sh
git add config/deploy.yml
git commit -F - <<'MSG'
The published image builds for amd64 and arm64

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
MSG
```

---

### Task 9: the real runs (orchestrator, after Tasks 1–8 are merged into the branch)

**Files:** none. Results go in the arc.

- [ ] **Step 1: This Mac, Docker Desktop, the four-service stack from the compose file over locally built images**

```sh
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build 2>&1 | tail -5
until curl -fsS http://localhost:8080/up >/dev/null; do sleep 3; done; echo up
docker compose ps
```

Then, in the browser: sign up (the page must say "first account"), confirm the Recent page shows
Getting started, open `/users/sign_up` again in a private window and see "Sign-ups are closed",
upload a file and confirm it appears in `./library`, open Tools and save a box, open the OpenSCAD
tool. Record: `docker compose ps` output, `uname -m`, the image's arch (`docker image inspect
tinkerex:local --format '{{.Architecture}}'`), and the time to first `/up`.

- [ ] **Step 2: The Linux Docker host, 192.168.1.146, the uid cases**

Copy the branch there (or clone it), build with the overlay, and run three starts:

1. default: `docker compose … up -d` with no `./library` present → it is auto-created by Docker, root-owned; the boot must succeed (the entrypoint adopts it); `stat -c %u:%g library` must read `1000:1000`.
2. `PUID=$(id -u) PGID=$(id -g)` against an existing folder owned by that uid → boots; an upload lands owned by that uid.
3. a non-empty folder owned by another uid with `PUID=1000` → the boot is refused by the probe ("is not writable"), and `stat` shows the folder untouched.

Record each outcome verbatim. If the host is not reachable over ssh, say so in the arc and in the
PR: the Linux uid path is then verified only by the unit test and the Step 6 `docker run` of Task 4.

- [ ] **Step 3: Tear down**

`docker compose down -v` on both machines (the Mac's named volumes included), `rm -rf library`.

- [ ] **Step 4: Full gates**

`bin/ci` from the branch; read the three backend legs' run counts and confirm they are identical.
