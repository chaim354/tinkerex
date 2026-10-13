# C — A stranger can install it: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repo `.claude/commands/execute-plan.md` governs batching: Tasks 1, 2 and 3 touch disjoint files and run in parallel in their own worktrees; Task 4 is the orchestrator's.

**Goal:** A stranger with Docker on a Linux box clones the repo, copies `.env.example`, runs `docker compose up`, opens the page, creates the owner account, and sees their files — with nothing from the author's Mac, Kamal or 1Password involved.

**Architecture:** Three small config changes (encryption keys from ENV, a production-only boot refusal for a blank backend, Solid Queue on by default in production), each a pure function with a unit test and an initializer that applies it; a Dockerfile that builds on arm64 by `TARGETARCH`; a compose file plus an overlay, an env reference guarded by a test, a real README and an Unraid template. Design: `docs/superpowers/specs/2026-10-13-c-install-path-design.md`.

**Facts the tasks rely on (measured 2026-10-13; file:line against this branch):**
- `secret_key_base`: ENV wins before credentials (`railties-8.1.3.1/lib/rails/application/configuration.rb:523-533`). Encryption keys: the railtie calls `configure(primary_key: credentials..., **app.config.active_record.encryption)` (`activerecord-8.1.3.1/lib/active_record/railtie.rb:361-368`), and a runtime splat overrides the kwarg, so a value set on `config.active_record.encryption` in an initializer wins over the credential; keys are validated lazily on first encrypt/decrypt.
- No master key + committed `credentials.yml.enc` → credentials read as `{}` silently (`require_master_key` is false); a WRONG key raises `InvalidMessage` at boot. So a stranger must NOT set `RAILS_MASTER_KEY`.
- `LIBRARY_BACKEND` unset in production: `config/initializers/library_backend_check.rb:20-22` → `check!` with default `chunk` → no case arm → boot succeeds; then `config/initializers/content_security_policy.rb:53-56`'s `connect_src` lambda calls `FileLayer.current` on EVERY response → `LibraryBackendCheck::Error` in middleware → 500 on every request including `/up`.
- `assets:precompile` boots the full production environment during the image build with nothing set and `SECRET_KEY_BASE_DUMMY=1` (`Dockerfile:24,78`); Rails itself treats `SECRET_KEY_BASE_DUMMY` as the "not a real boot" marker.
- `config/puma.rb:38`: `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]` — any non-empty value enables; the author's destinations set `true` (`config/deploy.yml:92`); nothing else reads it.
- `Dockerfile:109`: `pdfium-webassembly-linux-amd64` from klippa-app/pdfium-cli v0.11.0, which also ships `pdfium-webassembly-linux-arm64`; `Dockerfile:123,128`: `F3D-3.5.0-Linux-x86_64.tar.xz` — F3D has NO Linux arm64 asset; `app/services/maker/previews/mesh.rb:34-40` answers `unsupported` when the binary is absent; resvg and stl-thumbnailer are cargo-built (arch-neutral); jemalloc uses `uname -m`.
- Thruster listens on 80 inside the container (`Dockerfile:203-204`); the entrypoint runs `db:prepare` on `bin/rails server`; everything durable is `/rails/storage` (four SQLite files + previews); the image runs as uid/gid 1000 and the share path is touch-probed at boot as that user.
- Sidecars listen on 8000 (`sidecar/boxes/Dockerfile:33-36`, `sidecar/openscad/Dockerfile:121-125`); the addon bundle is an nginx image on 80 (`../tinkerex-addons/Dockerfile`); `ADDON_SOURCE_PATH` works in production (`app/services/maker/addons/source.rb:31-33`).
- Every ghcr package is private (anonymous token endpoint answers 401 for all five); visibility is per package, an owner action (audit §6).

**Conventions that bind every task:** tests run with `LIBRARY_PATH=$(mktemp -d) LIBRARY_BACKEND=share bin/rails test <files>`; `lib/` is on the load path and autoloaded (`config.autoload_lib`); a file `config/puma.rb` needs must be plain Ruby with no Rails constants (Puma loads it before the app); mutation-check every guard (break it, run the named test, report the output, restore with `git checkout -- <file>` and `rm -rf tmp/cache/bootsnap*`); commit per task with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`, no backticks or `!` in messages; `bin/rubocop` on touched Ruby.

---

### Task 1: Three config seams — encryption keys from ENV, a blank backend refused in production, Solid Queue on by default

**Files:**
- Create: `lib/tinkerex/encryption_keys.rb`, `lib/tinkerex/solid_queue_in_puma.rb`
- Modify: `config/initializers/active_record_encryption.rb`, `config/initializers/library_backend_check.rb`, `lib/library_backend_check.rb` (one new method), `config/puma.rb`
- Create: `test/lib/encryption_keys_test.rb`, `test/lib/solid_queue_in_puma_test.rb`, `test/lib/library_backend_required_test.rb`

- [ ] **Step 1: Write the failing tests**

`test/lib/encryption_keys_test.rb`:

```ruby
require "test_helper"

# A stranger runs with SECRET_KEY_BASE and three ACTIVE_RECORD_ENCRYPTION_* variables and NO master
# key; the author's deployments keep their credentials. The function returns only the keys that
# are PRESENT: assigning nil would be splatted over the credential value by the railtie and break
# every credentials-based deployment (the design records why).
class EncryptionKeysTest < ActiveSupport::TestCase
  test "nothing when nothing is set" do
    assert_equal({}, Tinkerex::EncryptionKeys.from_env({}))
    assert_equal({}, Tinkerex::EncryptionKeys.from_env({ "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "" }))
  end

  test "each present key, under the name config.active_record.encryption takes" do
    env = { "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "p" * 32,
            "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY" => "d" * 32,
            "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT" => "s" * 32 }
    assert_equal({ primary_key: "p" * 32, deterministic_key: "d" * 32, key_derivation_salt: "s" * 32 },
                 Tinkerex::EncryptionKeys.from_env(env))
  end

  test "a partial set is passed through partially — the missing one still comes from credentials" do
    assert_equal({ primary_key: "p" * 32 },
                 Tinkerex::EncryptionKeys.from_env({ "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY" => "p" * 32 }))
  end
end
```

`test/lib/solid_queue_in_puma_test.rb`:

```ruby
require "test_helper"

# Background work (scans, previews, purges, intake, the changelog pull) runs in Solid Queue, and
# until 2026-10-13 it ran only when SOLID_QUEUE_IN_PUMA was set to anything at all — so a stranger's
# container did none of it, silently. On by default in production; false/0/no is a real off-switch
# for a split bin/jobs container; outside production the old opt-in stays.
class SolidQueueInPumaTest < ActiveSupport::TestCase
  def on?(env, production:) = Tinkerex::SolidQueueInPuma.enabled?(env, production:)

  test "on by default in production, off by default elsewhere" do
    assert on?({}, production: true)
    assert_not on?({}, production: false)
  end

  test "an explicit value wins in every environment" do
    assert on?({ "SOLID_QUEUE_IN_PUMA" => "true" }, production: false)
    assert on?({ "SOLID_QUEUE_IN_PUMA" => "1" }, production: false)
    %w[false 0 no False].each do |off|
      assert_not on?({ "SOLID_QUEUE_IN_PUMA" => off }, production: true), off
    end
  end
end
```

`test/lib/library_backend_required_test.rb`:

```ruby
require "test_helper"

# With LIBRARY_BACKEND blank, production used to boot and then answer 500 to EVERY request,
# including /up: the CSP header's connect_src lambda calls FileLayer.current on every response,
# which raises inside middleware. The boot now refuses instead — in production only (an
# unconfigured development box must still boot, CLAUDE.md §14a), and not during the image build's
# assets:precompile, which Rails marks with SECRET_KEY_BASE_DUMMY.
class LibraryBackendRequiredTest < ActiveSupport::TestCase
  def required!(env, production: true) = LibraryBackendCheck.required_in_production!(env: env, production: production)

  test "a blank backend is refused in production, naming the three values" do
    e = assert_raises(LibraryBackendCheck::Error) { required!({}) }
    assert_match(/share \| s3 \| chunk_remote/, e.message)
    assert_raises(LibraryBackendCheck::Error) { required!({ "LIBRARY_BACKEND" => " " }) }
  end

  test "a set backend, a non-production boot, and the precompile boot all pass" do
    assert_nil required!({ "LIBRARY_BACKEND" => "share" })
    assert_nil required!({}, production: false)
    assert_nil required!({ "SECRET_KEY_BASE_DUMMY" => "1" })
  end
end
```

- [ ] **Step 2: Run them** — expected NameErrors / NoMethodError for the three new entry points.

- [ ] **Step 3: Implement**

`lib/tinkerex/encryption_keys.rb`:

```ruby
module Tinkerex
  # Active Record encryption keys from the ENVIRONMENT, for a deployment that has no master key.
  # Rails reads these only from credentials; this app's credentials.yml.enc is committed and baked
  # into the image, and only the author holds its key. A value set on
  # config.active_record.encryption in an initializer is splatted over the credential by the
  # railtie, so present ENV values win and absent ones leave the credential alone — ONLY WHEN
  # PRESENT is load-bearing: a nil would win too and break every credentials-based deployment.
  module EncryptionKeys
    NAMES = %w[primary_key deterministic_key key_derivation_salt].freeze

    def self.from_env(env = ENV)
      NAMES.each_with_object({}) do |name, keys|
        value = env["ACTIVE_RECORD_ENCRYPTION_#{name.upcase}"].to_s
        keys[name.to_sym] = value if value.present?
      end
    end
  end
end
```

`config/initializers/active_record_encryption.rb` — add ABOVE the existing `support_unencrypted_data` line (keep that line and its comment):

```ruby
# KEYS FROM THE ENVIRONMENT, FOR A BOX WITH NO MASTER KEY (C, 2026-10-13; lib/tinkerex/encryption_keys.rb
# says why only-when-present matters). The author's deployments set none of these and keep reading
# credentials. A stranger's chunk_remote deployment sets all three (any 32+ character strings) and
# never RAILS_MASTER_KEY — a wrong key crashes the boot, an absent one reads empty credentials.
require "tinkerex/encryption_keys"
Tinkerex::EncryptionKeys.from_env.each do |name, value|
  Rails.application.config.active_record.encryption.public_send("#{name}=", value)
end
```

`lib/library_backend_check.rb` — add after `check!`:

```ruby
  # PRODUCTION REFUSES TO BOOT WITH NO BACKEND NAMED. check!'s own default (`chunk`, deliberately
  # NOT the factory's `share` — §14a) lets an unconfigured development box boot; in production the
  # same gap used to boot cleanly and then 500 on EVERY request, /up included, because the CSP
  # header's connect_src lambda resolves FileLayer.current per response and the raise happens in
  # middleware. Exempt: the image build's assets:precompile, which Rails marks with
  # SECRET_KEY_BASE_DUMMY and which boots production with nothing set.
  def self.required_in_production!(env: ENV, production: Rails.env.production?)
    return nil unless production
    return nil if env["SECRET_KEY_BASE_DUMMY"].present?
    return nil if env["LIBRARY_BACKEND"].to_s.strip.present?

    raise Error, "LIBRARY_BACKEND is not set (share | s3 | chunk_remote). A production deployment " \
                 "must name its library backend; without one every request, /up included, answers 500."
  end
```

`config/initializers/library_backend_check.rb` — replace the `after_initialize` block body with:

```ruby
Rails.application.config.after_initialize do
  unless Rails.env.test?
    LibraryBackendCheck.required_in_production!
    LibraryBackendCheck.check!
  end
end
```

`lib/tinkerex/solid_queue_in_puma.rb` (PLAIN RUBY — Puma loads config/puma.rb before Rails exists):

```ruby
module Tinkerex
  # Whether Puma runs the Solid Queue supervisor in-process (config/puma.rb). On by default in
  # production — a single-container deployment did no background work at all until 2026-10-13
  # unless the operator knew the variable — with false/0/no as the off-switch for a split
  # bin/jobs container. No Rails constants: Puma evaluates its config before the app boots.
  module SolidQueueInPuma
    OFF = %w[false 0 no].freeze

    def self.enabled?(env = ENV, production: env["RAILS_ENV"] == "production")
      value = env["SOLID_QUEUE_IN_PUMA"].to_s.strip
      return production if value.empty?

      !OFF.include?(value.downcase)
    end
  end
end
```

`config/puma.rb` — replace the `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]` line (keep its comment, extend it) with:

```ruby
# On by default in production; SOLID_QUEUE_IN_PUMA=false for a split bin/jobs container
# (lib/tinkerex/solid_queue_in_puma.rb, plain Ruby because this file runs before Rails).
require_relative "../lib/tinkerex/solid_queue_in_puma"
plugin :solid_queue if Tinkerex::SolidQueueInPuma.enabled?
```

- [ ] **Step 4: Run** the three new tests plus `test/architecture_invariants_test.rb test/ci_hygiene_test.rb` (they scan initializers / config) — expected PASS. Also boot checks (development, which has no `RAILS_ENV=production`): `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d) bin/rails runner 'puts :ok'` → `ok`; and the production refusal, measured: `RAILS_ENV=production SECRET_KEY_BASE=$(openssl rand -hex 64) bin/rails runner 'puts :booted' 2>&1 | tail -2` → the refusal naming the three values (do NOT set RAILS_MASTER_KEY; this worktree has config/master.key, which Rails will read — fine); then the same with `LIBRARY_BACKEND=share LIBRARY_PATH=$(mktemp -d)` → `booted`. Also `RAILS_ENV=production SECRET_KEY_BASE_DUMMY=1 bin/rails runner 'puts :precompile_boot'` → `precompile_boot`. Report all four outputs. Zeitwerk: `bin/rails zeitwerk:check` → "All is good".

- [ ] **Step 5: Mutation-check** — (a) make `from_env` return `{ primary_key: nil }` for an empty env: the first test RED; (b) drop the `SECRET_KEY_BASE_DUMMY` exemption: the third test's last assertion RED; (c) make `enabled?` return `false` when the value is empty: the first SolidQueue test RED. Restore each, clear bootsnap, report outputs.

- [ ] **Step 6: Commit** — subject "Encryption keys from the environment, a blank backend refused in production, and Solid Queue on by default".

---

### Task 2: The image builds for arm64

**Files:** `Dockerfile` only.

- [ ] **Step 1: Change the two stages**

pdfium stage: declare `ARG TARGETARCH` after `FROM base AS pdfium` and use `pdfium-webassembly-linux-${TARGETARCH}` in the URL (klippa-app/pdfium-cli v0.11.0 ships both amd64 and arm64).

F3D stage: declare `ARG TARGETARCH`; download and extract ONLY when `TARGETARCH` is `amd64`, otherwise `mkdir -p /opt/f3d` and write `/opt/f3d/README.txt` saying F3D has no Linux arm64 build and STEP/IGES/OBJ thumbnails are unavailable on this architecture. The final stage's `COPY --from=f3d /opt/f3d /opt/f3d` and `ENV F3D_BIN` stay as they are: `Maker::Previews::Mesh#available?` answers false when the binary is absent and those files show the generic icon. Update the stage comment ("The deploy builds linux/amd64 … so x86_64 is the right asset") to say what happens on arm64 and why.

Check the rest of the Dockerfile for other architecture assumptions (`grep -n "x86_64\|amd64" Dockerfile`) and handle each the same way or explain in a comment why it is already arch-neutral (jemalloc uses `uname -m`; resvg and stl-thumbnailer are cargo builds).

- [ ] **Step 2: Verify BOTH builds**

```sh
# amd64, the production path, through the same buildx builder the deploy uses (cache-warm):
docker buildx build --platform linux/amd64 --builder kamal-local-docker-container -t tinkerex:c-amd64 --load .
docker run --rm --platform linux/amd64 tinkerex:c-amd64 /opt/f3d/bin/f3d --version | head -1   # prints F3D 3.5.0
docker run --rm --platform linux/amd64 tinkerex:c-amd64 pdfium --help | head -1
# arm64, native on this Mac:
docker build --platform linux/arm64 -t tinkerex:c-arm64 .
docker run --rm tinkerex:c-arm64 sh -c 'test -f /opt/f3d/README.txt && echo no-f3d-as-designed; pdfium --help | head -1; resvg --version; stl-thumbnailer --help 2>&1 | head -1'
```

Report the actual outputs. If the arm64 build fails in a stage you did not change (a gem's native extension, an apt package), report exactly where and stop — do not widen the task.

- [ ] **Step 3: Commit** — subject "The image builds for arm64: pdfium by TARGETARCH, F3D only where upstream ships it". Do not push.

---

### Task 3: The compose files, the env reference and its guard, the README, the Unraid template

**Files:**
- Create: `docker-compose.yml`, `docker-compose.chunk_remote.yml`, `.env.example`, `docs/INSTALL.md`, `unraid/tinkerex.xml`, `test/install_docs_test.rb`
- Replace: `README.md`

- [ ] **Step 1: Write the failing guard**

`test/install_docs_test.rb`:

```ruby
require "test_helper"

# docs/INSTALL.md IS THE ENVIRONMENT REFERENCE, and this is what keeps it complete: every variable
# the app reads (`ENV["X"]`, `ENV.fetch("X"...)`, `env["X"]` in the two lib modules that take an env
# hash) must appear there, except the names below, which are dev/CI/author-only and documented
# where they are used. A variable added to the code and not to the doc fails here.
class InstallDocsTest < ActiveSupport::TestCase
  DOC = Rails.root.join("docs/INSTALL.md")
  ROOTS = %w[app lib config bin/docker-entrypoint bin/thrust].freeze
  NOT_FOR_INSTALLERS = %w[
    RAILS_ENV RAILS_LOG_LEVEL RAILS_MASTER_KEY SECRET_KEY_BASE_DUMMY BUNDLE_WITHOUT BUNDLE_DEPLOYMENT
    PORT PIDFILE WEB_CONCURRENCY JOB_CONCURRENCY ENABLE_TEST_SIGNUP CHUNK_REMOTE_TOKEN
    TEST_LIBRARY_PATH CI CI_RUNNERS GITHUB_ACTIONS GITHUB_ENV GITHUB_OUTPUT KAMAL_REGISTRY_PASSWORD
    OP_SERVICE_ACCOUNT_TOKEN TINKEREX_SYNC_DIR SYNC_IMPL SYNC_PORT LOG_SPOOL_DIR LOG_BRANCH KANEO_URL
    KANEO_WORKSPACE KANEO_PROJECT GH_BIN DRY_RUN APPLY HOME PATH TMPDIR LANG
  ].freeze

  def names_read_by_the_code
    pattern = /\bENV(?:\.fetch\(|\[)\s*["']([A-Z][A-Z0-9_]+)["']|\benv\[\s*["']([A-Z][A-Z0-9_]+)["']\]/
    ROOTS.flat_map { |root|
      path = Rails.root.join(root)
      files = path.directory? ? Dir[path.join("**/*.{rb,erb,yml,rake}")] : [ path.to_s ]
      files.flat_map { |f| File.read(f).scan(pattern).flatten.compact }
    }.uniq.sort
  end

  test "every variable the app reads is documented in docs/INSTALL.md" do
    names = names_read_by_the_code - NOT_FOR_INSTALLERS
    assert_operator names.size, :>=, 20, "the scan found too few variables — did the pattern or the roots break?"
    doc = DOC.read
    missing = names.reject { |n| doc.include?("`#{n}`") }
    assert_empty missing, "add these to the table in docs/INSTALL.md (or to NOT_FOR_INSTALLERS with a reason): #{missing.join(', ')}"
  end

  test "the compose file and the env example name no variable the doc does not" do
    doc = DOC.read
    %w[docker-compose.yml docker-compose.chunk_remote.yml .env.example].each do |file|
      used = Rails.root.join(file).read.scan(/\b([A-Z][A-Z0-9_]{3,})(?:=|:)/).flatten.uniq - NOT_FOR_INSTALLERS
      undocumented = used.reject { |n| doc.include?("`#{n}`") }
      assert_empty undocumented, "#{file} uses #{undocumented.join(', ')} but docs/INSTALL.md does not explain them"
    end
  end
end
```

Run it first: it fails on the missing doc. Note `names_read_by_the_code` scans `.yml` too (`config/recurring.yml`, `database.yml` use `<%= ENV["X"] %>`), so `DATABASE_URL`, `DB_SSLMODE`, `SOLID_*_DATABASE_URL` will surface — document them in an "Advanced: Postgres" row. If the scan surfaces a name that is genuinely internal, add it to `NOT_FOR_INSTALLERS` with a comment, never by loosening the pattern.

- [ ] **Step 2: `docs/INSTALL.md`** — sections, in order:
  1. **What you need**: Docker + Compose, a Linux box (amd64; arm64 works without STEP/IGES/OBJ thumbnails and without the openscad tool), a folder of files (the library) or an empty one.
  2. **Quick start (share backend)**: clone; `cp .env.example .env`; set `SECRET_KEY_BASE` (`openssl rand -hex 64`), `LIBRARY_HOST_PATH` (the folder, must be writable by uid 1000: `sudo chown -R 1000:1000 <path>` or a matching user), `APP_HOST`; `docker compose up -d --build`; open `http://<host>:8080`; **the first account you create is the owner** (confirmed on the spot, no mail); sign-ups then close. Where your files come from: the folder is scanned every 15 minutes and on the Rescan button; uploads in the browser land in it; folders under `Projects/` become projects. One paragraph each, plain.
  3. **The Tools gallery (optional)**: `docker compose --profile tools up -d --build` builds the two GPL sidecars from `sidecar/` and serves the addon bundle from a sibling checkout (`git clone https://github.com/chaim354/tinkerex-addons ../tinkerex-addons`); without the profile the gallery is empty and says so.
  4. **Mail and more accounts**: `SMTP_*`, `MAIL_FROM`, `REGISTRATION` (and why `open` is refused on share/s3), the two rake tasks via `docker compose exec web bin/rails 'tinkerex:owner[EMAIL]'` with `TINKEREX_PASSWORD` set via `-e`.
  5. **The sync server (chunk_remote)**: `docker compose -f docker-compose.yml -f docker-compose.chunk_remote.yml up -d --build` needs `../tinkerex-sync` cloned (its `Dockerfile.rust`), `SYNC_ADMIN_TOKEN` (shared), the three `ACTIVE_RECORD_ENCRYPTION_*` keys (`openssl rand -hex 16` each; keep them — losing them orphans every device token), and that devices reach the sync service on its published port; what it gives (per-user libraries, versions, trash restore, the desktop client).
  6. **Updating**: `git pull && docker compose up -d --build`; migrations run on start; previews regenerate; `.env` is never overwritten.
  7. **Backups**: everything durable is the `tinkerex_storage` volume (four SQLite files + previews) and your library folder; a WAL-safe copy is `docker compose exec web sqlite3 /rails/storage/production.sqlite3 ".backup /rails/storage/backup.sqlite3"` then copy the volume; never `docker cp` a live SQLite file.
  8. **Environment reference** — ONE table, every variable, columns: variable · required? · default · what it does. Source it from `docs/AUDIT-2026-10-12-readiness.md` §5's table (copy, then verify each row against the code the row cites), plus B's (`REGISTRATION`, `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USER_NAME`, `SMTP_PASSWORD`, `SMTP_DOMAIN`, `SMTP_AUTHENTICATION`, `SMTP_STARTTLS`, `MAIL_FROM`, `TINKEREX_PASSWORD`) and C's (`ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY`, `_DETERMINISTIC_KEY`, `_KEY_DERIVATION_SALT`, `SOLID_QUEUE_IN_PUMA` now defaulting on). Spell each name in backticks exactly once per row so the guard matches.
  9. **Never set `RAILS_MASTER_KEY`** unless you regenerated `config/credentials.yml.enc` yourself — one paragraph, the measured reason.
  10. **Where the author's own deploy recipe lives**: `docs/DEPLOY.md` (Kamal, 1Password, the author's hosts) — not for strangers.

- [ ] **Step 3: `docker-compose.yml`** (share, with the `tools` profile):

```yaml
# A single-owner install on the share backend. docs/INSTALL.md explains every variable.
services:
  web:
    image: ${TINKEREX_IMAGE:-tinkerex:local}
    build: .
    ports: ["${TINKEREX_PORT:-8080}:80"]
    env_file: .env
    environment:
      LIBRARY_BACKEND: share
      LIBRARY_PATH: /library
    volumes:
      - tinkerex_storage:/rails/storage
      - ${LIBRARY_HOST_PATH:?set LIBRARY_HOST_PATH in .env to the folder that holds your files}:/library
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost/up"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 90s
    restart: unless-stopped

  boxes:
    profiles: [tools]
    build: sidecar/boxes
    restart: unless-stopped
  openscad:
    profiles: [tools]
    build: sidecar/openscad
    volumes: [openscad_cache:/cache]
    restart: unless-stopped
  addons:
    profiles: [tools]
    build: ${TINKEREX_ADDONS_PATH:-../tinkerex-addons}
    restart: unless-stopped

volumes:
  tinkerex_storage: {}
  openscad_cache: {}
```

and in `.env.example` the tools wiring is commented out by default:
`# BOXES_SIDECAR_URL=http://boxes:8000`, `# OPENSCAD_SIDECAR_URL=http://openscad:8000`, `# ADDON_SOURCE_URL=http://addons` — with one line saying to uncomment them when starting with `--profile tools`. `.env.example` lists, with comments: `SECRET_KEY_BASE=` (how to generate), `LIBRARY_HOST_PATH=`, `APP_HOST=`, `TINKEREX_PORT=8080`, `RAILS_MAX_THREADS=16`, `# REGISTRATION=closed`, `# SMTP_ADDRESS=` and the other SMTP lines, `# MAIL_FROM=`, `# FORCE_SSL=1`, `# LIBRARY_TRASH_DAYS=30`, `# TINKEREX_IMAGE=ghcr.io/chaim354/tinkerex:latest` (once the package is public). `SOLID_QUEUE_IN_PUMA` needs no line now (Task 1 defaults it on) — mention that in a comment.

`docker-compose.chunk_remote.yml` (overlay):

```yaml
# docker compose -f docker-compose.yml -f docker-compose.chunk_remote.yml up -d --build
services:
  web:
    environment:
      LIBRARY_BACKEND: chunk_remote
      LIBRARY_PATH: ""
      CHUNK_REMOTE_URL: http://sync:3000
    volumes:
      - tinkerex_storage:/rails/storage
    depends_on: [sync]
  sync:
    build:
      context: ${TINKEREX_SYNC_PATH:-../tinkerex-sync}
      dockerfile: Dockerfile.rust
    environment:
      STORAGE_BACKEND: local
      CHUNK_LOCAL_DIR: /rails/host/storage/chunk-store
      SECRET_KEY_BASE: ${SYNC_SECRET_KEY_BASE:?openssl rand -hex 64}
      SYNC_ADMIN_TOKEN: ${SYNC_ADMIN_TOKEN:?openssl rand -hex 32, shared with web}
    ports: ["${SYNC_PORT:-3001}:3000"]
    volumes: [tinkerex_sync_storage:/rails/host/storage]
    restart: unless-stopped
volumes:
  tinkerex_sync_storage: {}
```

Check `../tinkerex-sync/Dockerfile.rust` and `crates/tinkerex-sync/README.md` for the exact env names and the storage path it expects, and correct the overlay to match them — do not trust the sketch. `web` in the overlay also needs `SYNC_ADMIN_TOKEN` and the three `ACTIVE_RECORD_ENCRYPTION_*` from `.env`; the `volumes` override above is deliberate (compose merges lists, so the share bind mount from the base file would otherwise remain — verify with `docker compose -f … -f … config` that `/library` is gone from `web`).

- [ ] **Step 4: `unraid/tinkerex.xml`** — a Community Applications template for the share install: Name `Tinkerex`, Repository `ghcr.io/chaim354/tinkerex:latest` (with a top-of-file comment that it works once the package is public and that `docker compose` is the path meanwhile), Network `bridge`, WebUI `http://[IP]:[PORT:80]/`, Port 80→8080, Paths `/mnt/user/appdata/tinkerex/storage`→`/rails/storage` and a library share→`/library` (both RW, must be writable by uid 1000 — say so in the description), Variables: `SECRET_KEY_BASE` (Mask), `LIBRARY_BACKEND=share` (hidden/fixed), `LIBRARY_PATH=/library` (fixed), `RAILS_MAX_THREADS=16`, `APP_HOST`, optional `REGISTRATION`, `SMTP_ADDRESS`, `SMTP_USER_NAME`, `SMTP_PASSWORD` (Mask), `MAIL_FROM`, `LIBRARY_TRASH_DAYS`. Follow the CA template schema (`<Container version="2">`, `<Config Type="Port|Path|Variable" …>`).

- [ ] **Step 5: `README.md`** — replace the scaffold with: one paragraph what it is (a self-hosted library for a maker's files — 3D, CAD, laser — with previews, projects, inventory and a Tools gallery; the desktop sync client lives in `chaim354/tinkerex-client` and is still being brought up); **Status** (runs on real hardware; three library backends: a folder you point it at, your own S3 bucket, or the sync server); **Quick start** (the five compose steps, linking `docs/INSTALL.md`); **First run** (the owner account); **Where files come from**; **The Tools gallery**; **Updating and backups** (one line each, linking the doc); **The repositories** (this one, `tinkerex-sync` MIT, `tinkerex-client` Apache-2.0, `tinkerex-addons` MIT); **Developing** (`bin/setup`, `bin/ci`, the three backend legs, `CLAUDE.md` for the architecture); **Licence**: "This repository's licence has not been chosen yet; until it is, all rights are reserved. The sibling repositories are MIT and Apache-2.0." No marketing, no screenshots.

- [ ] **Step 6: Verify** — `docker compose config` and `docker compose -f docker-compose.yml -f docker-compose.chunk_remote.yml config` both parse (set the required vars in a throwaway `.env` for the check; do not commit `.env`); the guard test passes; `test/docs_hygiene_test.rb` passes; `bin/rubocop test/install_docs_test.rb` clean. Mutation-check the guard: delete the `APP_HOST` row from INSTALL.md → RED naming it; restore.

- [ ] **Step 7: Commit** — subject "A stranger can install it: compose files, the env reference and its guard, a real README, an Unraid template".

---

### Task 4 (orchestrator): end-to-end, docs, gates, PR

1. With Tasks 1–3 merged: build the image natively (`docker compose build` on this arm64 Mac), create a temp library with a few files, `docker compose up -d`, then drive it: `/up` 200; the sign-up page shows the first-owner note; create the owner through the real form (cookie jar + authenticity token); land signed in; `/files` lists the seeded files after a Rescan; the Tools gallery shows its empty state; `docker compose logs web` carries no error and no `ENABLE_TEST_SIGNUP` banner; `docker compose exec web bin/rails 'tinkerex:owner[second@example.com]'` with `-e TINKEREX_PASSWORD` creates a second account. Tear down with `docker compose down -v`.
2. `docs/AUDIT-2026-10-12-readiness.md`: mark §2.1 items 1 (buildable, compose), 2 (encryption keys from env), 3 (backend refusal), 4 (Solid Queue default), 5 (first account) and §2.1.9 (tools profile) as fixed by C; items on private images remain owner actions.
3. CLAUDE.md §14a: one line each for the three invariants the spec lists, within the ceiling (trim elsewhere if needed).
4. `bin/ci` (three identical run counts), `/finish-branch`, `bin/log arc --from-pr <n>`.
