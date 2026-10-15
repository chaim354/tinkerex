require "test_helper"

# docs/INSTALL.md IS THE ENVIRONMENT REFERENCE, and this is what keeps it complete: every variable
# the app reads (`ENV["X"]`, `ENV.fetch("X"...)`, and `env["X"]` / `env.fetch("X")` in the lib
# modules and adapters that take an env hash) must have a row in its reference table, except the
# names below, which are dev/CI/author-only and documented where they are used. A variable added
# to the code and not to the table fails here. The table may hold MORE than the code reads — the
# compose-only knobs, the sync server's own variables, the keys Rails itself consumes — never less.
class InstallDocsTest < ActiveSupport::TestCase
  DOC = Rails.root.join("docs/INSTALL.md")
  ROOTS = %w[app lib config bin/docker-entrypoint bin/thrust].freeze
  NOT_FOR_INSTALLERS = %w[
    RAILS_ENV RAILS_LOG_LEVEL RAILS_MASTER_KEY SECRET_KEY_BASE_DUMMY BUNDLE_WITHOUT BUNDLE_DEPLOYMENT
    PORT PIDFILE WEB_CONCURRENCY JOB_CONCURRENCY ENABLE_TEST_SIGNUP CHUNK_REMOTE_TOKEN
    TEST_LIBRARY_PATH CI CI_RUNNERS GITHUB_ACTIONS GITHUB_ENV GITHUB_OUTPUT KAMAL_REGISTRY_PASSWORD
    OP_SERVICE_ACCOUNT_TOKEN TINKEREX_SYNC_DIR SYNC_IMPL SYNC_PORT LOG_SPOOL_DIR LOG_BRANCH KANEO_URL
    KANEO_WORKSPACE KANEO_PROJECT GH_BIN DRY_RUN APPLY HOME PATH TMPDIR LANG
    BUNDLE_GEMFILE
  ].freeze
  # BUNDLE_GEMFILE is the Rails scaffold's own `config/boot.rb` line (`ENV["BUNDLE_GEMFILE"] ||=`),
  # bundler's knob and not this app's; CLAUDE.md §14j is where it matters, and only to a developer
  # spawning a second bundled process.

  # `env` as well as `ENV`, and `.fetch(` as well as `[`: FileLayer::S3.from_env reads its five
  # LIBRARY_S3_* knobs as `env.fetch("...")` on an injected hash, and a pattern that only knew
  # `env[` missed the audit's own required-for-s3 row. Loosening is never the answer to a name the
  # scan surfaces (add it to NOT_FOR_INSTALLERS, with a reason); widening what it catches is.
  #
  # THE BOOT GUARD'S REQUIRED KNOBS COUNT AS READ, though no literal names them: LibraryBackendCheck
  # reads each one as `env[knob]` over a constant, which the pattern cannot see. They are the names
  # a stranger most needs a row for -- the refusal that stops their boot names them, and this page
  # is where they look them up. SYNC_PUBLIC_URL arrived that way (D1, 2026-10-13), required at boot
  # one task before any code read it by name.
  def names_read_by_the_code
    pattern = /\b(?:ENV|env)(?:\.fetch\(|\[)\s*["']([A-Z][A-Z0-9_]+)["']/
    scanned = ROOTS.flat_map { |root|
      path = Rails.root.join(root)
      files = path.directory? ? Dir[path.join("**/*.{rb,erb,yml,rake}")] : [ path.to_s ]
      files.flat_map { |f| File.read(f).scan(pattern).flatten.compact }
    }
    (scanned + LibraryBackendCheck::CHUNK_REMOTE_REQUIRED + LibraryBackendCheck::S3_REQUIRED).uniq.sort
  end

  # A NAME COUNTS AS DOCUMENTED ONLY WHEN IT HEADS A ROW OF THE TABLE — the backticked names in a
  # table line's FIRST cell — not when it appears somewhere on the page. The first draft asked
  # `doc.include?("`NAME`")`, and its own mutation check (delete the APP_HOST row) stayed GREEN:
  # the quick start and two other rows' cells mention `APP_HOST` in passing, and a mention is not
  # a reference entry. A row may head several names (`SMTP_USER_NAME`, `SMTP_PASSWORD`); the bold
  # group rows and the header contribute nothing, having no backticks.
  def documented_names
    DOC.read.lines.filter_map { |line|
      next unless line.start_with?("|")

      line.split("|")[1]&.scan(/`([A-Z][A-Z0-9_]+)`/)&.flatten
    }.flatten.uniq
  end

  test "every variable the app reads has a row in docs/INSTALL.md's reference table" do
    names = names_read_by_the_code - NOT_FOR_INSTALLERS
    assert_operator names.size, :>=, 20, "the scan found too few variables — did the pattern or the roots break?"
    documented = documented_names
    assert_operator documented.size, :>=, 20, "the table parse found almost nothing — did the table's shape change?"
    missing = names - documented
    assert_empty missing, "add a row to the table in docs/INSTALL.md (or NOT_FOR_INSTALLERS, with a reason) for: #{missing.join(', ')}"
  end

  test "the compose files and the env example name no variable the table does not" do
    documented = documented_names
    %w[docker-compose.yml docker-compose.build.yml docker-compose.chunk_remote.yml .env.example].each do |file|
      used = Rails.root.join(file).read.scan(/\b([A-Z][A-Z0-9_]{3,})(?:=|:)/).flatten.uniq - NOT_FOR_INSTALLERS
      floor = file == "docker-compose.build.yml" ? 1 : 3 # the build overlay names one: TINKEREX_ADDONS_PATH
      assert_operator used.size, :>=, floor, "#{file} names almost no variables — did the file or the pattern break?"
      undocumented = used - documented
      assert_empty undocumented, "#{file} uses #{undocumented.join(', ')} but docs/INSTALL.md's table has no row for them"
    end
  end
end
