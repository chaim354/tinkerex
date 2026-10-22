require "test_helper"
require "tmpdir"

# With LIBRARY_BACKEND blank, production used to boot and then answer 500 to EVERY request,
# including /up: the CSP header's connect_src lambda calls FileLayer.current on every response,
# which raises inside middleware. The boot now refuses instead — in production only (an
# unconfigured development box must still boot, CLAUDE.md §14a), and not during the image build's
# assets:precompile, which Rails marks with SECRET_KEY_BASE_DUMMY.
#
# AN UNKNOWN VALUE TOOK THE SAME ROAD UNTIL boot! (2026-10-19). A typo, a case or space variant or
# the retired `chunk` is not blank, so required_in_production! let it through, and the no-argument
# check! defaulted to `chunk`, matched no arm and checked nothing: the boot succeeded and every
# response 500'd. boot! reads LibraryBackendCheck.configured FIRST, so an unknown value refuses the
# boot everywhere, while nothing-named keeps both of its answers.
class LibraryBackendRequiredTest < ActiveSupport::TestCase
  def required!(env, production: true) = LibraryBackendCheck.required_in_production!(env: env, production: production)
  def boot!(env, production:) = LibraryBackendCheck.boot!(env: env, production: production)

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

  # --- boot!: the initializer's ONE call -------------------------------------------------------

  test "boot! refuses an UNKNOWN backend in production" do
    %w[chunk nope].each do |value|
      assert_raises(LibraryBackendCheck::UnknownBackend, value) { boot!({ "LIBRARY_BACKEND" => value }, production: true) }
    end
  end

  test "boot! refuses an UNKNOWN backend in development too" do
    %w[chunk nope].each do |value|
      assert_raises(LibraryBackendCheck::UnknownBackend, value) { boot!({ "LIBRARY_BACKEND" => value }, production: false) }
    end
  end

  test "boot! with nothing named: production refuses, development and the precompile boot" do
    assert_raises(LibraryBackendCheck::Error) { boot!({}, production: true) }
    assert_raises(LibraryBackendCheck::Error) { boot!({ "LIBRARY_BACKEND" => " " }, production: true) }
    assert_nil boot!({}, production: false)
    assert_nil boot!({ "SECRET_KEY_BASE_DUMMY" => "1" }, production: true)
  end

  # Proves check! still runs once a backend IS named -- outside production as well, which is where
  # bin/ci's local db:test:prepare and every dev server boot.
  test "boot! asks a NAMED backend's own check, in development too" do
    err = assert_raises(LibraryBackendCheck::Error) { boot!({ "LIBRARY_BACKEND" => "share" }, production: false) }
    assert_match(/requires LIBRARY_PATH/, err.message)
    Dir.mktmpdir do |d|
      assert_nothing_raised { boot!({ "LIBRARY_BACKEND" => "share", "LIBRARY_PATH" => d }, production: true) }
    end
  end

  # THE TEST ENV SKIPS THE INITIALIZER, SO ITS WIRING IS PINNED HERE, STATICALLY -- boot_scan_test's
  # shape. Every boot! test above calls boot! directly, so an initializer reverted to the old pair
  # (required_in_production!, then a no-argument check!) would reopen the unknown-value 500 with all
  # of them green. CI runs each gate with RAILS_ENV=test and never boots development, so this pin is
  # the only guard there. after_initialize, because writable! names Library::Scanner, which is not
  # autoloadable while initializers run (§14a).
  test "the boot initializer makes ONE call, boot!, inside after_initialize and outside the test env" do
    source = Rails.root.join("config/initializers/library_backend_check.rb").read
    code = source.lines.reject { |line| line.lstrip.start_with?("#") }.join
    assert_equal %w[boot!], code.scan(/LibraryBackendCheck\.(\w+[!?]?)/).flatten,
                 "the initializer must ask boot! and nothing else -- the old pair let an unknown backend boot"

    hook = code[/^Rails\.application\.config\.after_initialize do\n(.*?)^end$/m, 1]
    assert hook, "no after_initialize block: called at the top level, the check raises `uninitialized constant Library`"
    assert_includes hook, "LibraryBackendCheck.boot!"
    assert_includes hook, "unless Rails.env.test?", "the suite builds its adapters over explicit roots"
  end
end
