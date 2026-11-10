require "test_helper"

# docs/INSTALL.md IS THE ENVIRONMENT REFERENCE, and this is what keeps it complete: every variable
# the app reads (`ENV["X"]`, `ENV.fetch("X"...)`, and `env["X"]` / `env.fetch("X")` in the lib
# modules and adapters that take an env hash) must have a row in its reference table, except the
# names below, which are dev/CI/author-only and documented where they are used, and the hidden
# backends' (HIDDEN_BACKEND_VARIABLES). A variable added to the code and not to the table fails
# here. The table may hold MORE than the code reads — the compose-only knobs, the keys Rails itself
# consumes — never less.
class InstallDocsTest < ActiveSupport::TestCase
  DOC = Rails.root.join("docs/INSTALL.md")
  ROOTS = %w[app lib config bin/docker-entrypoint bin/thrust].freeze
  NOT_FOR_INSTALLERS = %w[
    RAILS_ENV RAILS_LOG_LEVEL RAILS_MASTER_KEY SECRET_KEY_BASE_DUMMY BUNDLE_WITHOUT BUNDLE_DEPLOYMENT
    PORT PIDFILE WEB_CONCURRENCY JOB_CONCURRENCY ENABLE_TEST_SIGNUP CHUNK_REMOTE_TOKEN
    TEST_LIBRARY_PATH CI CI_RUNNERS GITHUB_ACTIONS GITHUB_ENV GITHUB_OUTPUT KAMAL_REGISTRY_PASSWORD
    OP_SERVICE_ACCOUNT_TOKEN TINKEREX_SYNC_DIR SYNC_IMPL SYNC_PORT LOG_SPOOL_DIR LOG_BRANCH KANEO_URL
    KANEO_WORKSPACE KANEO_PROJECT GH_BIN DRY_RUN APPLY HOME PATH TMPDIR LANG
    BUNDLE_GEMFILE HTTP_X_FORWARDED_FOR REMOTE_ADDR
  ].freeze
  # BUNDLE_GEMFILE is the Rails scaffold's own `config/boot.rb` line (`ENV["BUNDLE_GEMFILE"] ||=`),
  # bundler's knob and not this app's; CLAUDE.md §14j is where it matters, and only to a developer
  # spawning a second bundled process. HTTP_X_FORWARDED_FOR and REMOTE_ADDR are not environment
  # variables at all: they are the Rack request header and peer address CloudflareOnly reads as
  # `env["…"]` on the request's env hash (config/initializers/trusted_proxies.rb), the same spelling
  # the scan looks for.

  # THE s3 AND chunk_remote BACKENDS STILL RUN (the author's Unraid destinations and the public OVH
  # box) BUT ARE NO LONGER OFFERED TO INSTALLERS (2026-11-10, docs/superpowers/specs/
  # 2026-11-10-hide-s3-sync-and-desktop-design.md), so their variables have no row and the page
  # must not name them. DERIVED from the boot guard's own required lists, so a knob the guard comes
  # to require is exempted with it; the optional ones are named here. A NEW variable read only by
  # those backends belongs in OPTIONAL; anything else still needs a row.
  HIDDEN_BACKEND_OPTIONAL = %w[
    LIBRARY_S3_ENDPOINT LIBRARY_S3_REGION LIBRARY_S3_PREFIX
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
  ].freeze
  HIDDEN_BACKEND_VARIABLES = (LibraryBackendCheck::S3_REQUIRED + LibraryBackendCheck::CHUNK_REMOTE_REQUIRED +
                              HIDDEN_BACKEND_OPTIONAL).uniq.freeze
  HIDDEN_WORDS = /\bS3\b|\bbuckets?\b|chunk[_-]remote|sync[ -]server|sync engine|tinkerex-sync|tinkerex-client|desktop (?:app|client)/i

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
    names = names_read_by_the_code - NOT_FOR_INSTALLERS - HIDDEN_BACKEND_VARIABLES
    assert_operator names.size, :>=, 20, "the scan found too few variables — did the pattern or the roots break?"
    documented = documented_names
    assert_operator documented.size, :>=, 20, "the table parse found almost nothing — did the table's shape change?"
    missing = names - documented
    assert_empty missing, "add a row to the table in docs/INSTALL.md (or NOT_FOR_INSTALLERS, with a reason) for: #{missing.join(', ')}"
  end

  test "the compose files and the env example name no variable the table does not" do
    documented = documented_names
    %w[docker-compose.yml docker-compose.build.yml .env.example].each do |file|
      used = Rails.root.join(file).read.scan(/\b([A-Z][A-Z0-9_]{3,})(?:=|:)/).flatten.uniq - NOT_FOR_INSTALLERS
      floor = file == "docker-compose.build.yml" ? 1 : 3 # the build overlay names one: TINKEREX_ADDONS_PATH
      assert_operator used.size, :>=, floor, "#{file} names almost no variables — did the file or the pattern break?"
      undocumented = used - documented
      assert_empty undocumented, "#{file} uses #{undocumented.join(', ')} but docs/INSTALL.md's table has no row for them"
    end
  end

  test "the install guide and the files it hands out name no hidden backend" do
    %w[docs/INSTALL.md docker-compose.yml docker-compose.build.yml .env.example].each do |file|
      text = Rails.root.join(file).read
      named = HIDDEN_BACKEND_VARIABLES.select { |v| text.include?(v) }
      assert_empty named, "#{file} names #{named.join(', ')}, a variable of a backend installers are not offered"
      hits = text.lines.each_with_index.filter_map { |l, i| "#{i + 1}: #{l.strip}" if l.match?(HIDDEN_WORDS) }
      assert_empty hits, "#{file} mentions a hidden backend:\n#{hits.join("\n")}"
    end
    refute Rails.root.join("docker-compose.chunk_remote.yml").exist?, "the sync-server overlay is not handed out"
  end
end
