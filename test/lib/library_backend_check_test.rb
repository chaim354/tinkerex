require "test_helper"
require "tmpdir"

class LibraryBackendCheckTest < ActiveSupport::TestCase
  test "chunk mode needs no library path" do
    assert_nothing_raised { LibraryBackendCheck.check!(backend: "chunk", env: {}) }
  end

  test "share mode refuses to boot without a path" do
    err = assert_raises(LibraryBackendCheck::Error) do
      LibraryBackendCheck.check!(backend: "share", env: {})
    end
    assert_match(/requires LIBRARY_PATH/, err.message)
  end

  test "share mode refuses to boot on a blank path" do
    assert_raises(LibraryBackendCheck::Error) { LibraryBackendCheck.check!(backend: "share", env: { "LIBRARY_PATH" => "  " }) }
  end

  test "share mode refuses to boot on a missing root" do
    err = assert_raises(LibraryBackendCheck::Error) do
      LibraryBackendCheck.check!(backend: "share", env: { "LIBRARY_PATH" => "/nonexistent-#{SecureRandom.hex(4)}" })
    end
    assert_match(/does not exist/, err.message,
                 "must name the actual problem — a path that is not there is a typo'd " \
                 "LIBRARY_PATH, NOT an unmounted share (an unmounted share exists and is empty)")
  end

  test "share mode refuses to boot when the root is a file rather than a directory" do
    Tempfile.create("library") do |f|
      err = assert_raises(LibraryBackendCheck::Error) do
        LibraryBackendCheck.check!(backend: "share", env: { "LIBRARY_PATH" => f.path })
      end
      assert_match(/not a directory/, err.message)
    end
  end

  test "share mode refuses to boot on an unreadable root" do
    Dir.mktmpdir do |dir|
      File.chmod(0o000, dir)
      skip "running as root: an unreadable directory is still readable" if File.readable?(dir)
      err = assert_raises(LibraryBackendCheck::Error) do
        LibraryBackendCheck.check!(backend: "share", env: { "LIBRARY_PATH" => dir })
      end
      assert_match(/not readable/, err.message)
    ensure
      File.chmod(0o700, dir)
    end
  end

  # Skipped under root rather than shipped as a test that passes for the wrong reason: root
  # bypasses the mode bits, so the probe SUCCEEDS on a 0500 directory and no assertion here would
  # hold. CI containers run as root. Precedent: share_test.rb's own root skip.
  test "share mode refuses to boot on a read-only root" do
    skip "root bypasses permission bits" if Process.uid.zero?
    Dir.mktmpdir do |d|
      File.chmod(0o500, d)
      begin
        err = assert_raises(LibraryBackendCheck::Error) do
          LibraryBackendCheck.check!(backend: "share", env: { "LIBRARY_PATH" => d })
        end
        assert_match(/writ/i, err.message)
      ensure
        File.chmod(0o755, d)
      end
    end
  end

  # The probe WRITES into a directory we do not own. It must leave nothing behind — a leaked
  # dotfile is not cosmetic here: Share#library_present? uses "the root is empty" as its
  # unmounted signal (and its header already names a stale .DS_Store as the known way that
  # fails), so a leaked probe file makes an unmounted share read as mounted and turns every
  # FetchError into a terminal NotFound.
  test "the writability probe leaves nothing behind" do
    Dir.mktmpdir do |d|
      LibraryBackendCheck.check!(backend: "share", env: { "LIBRARY_PATH" => d })
      assert_equal [], Dir.children(d), "the probe must clean up after itself"
    end
  end

  # Chunk mode must not touch the filesystem at all — the guard returns before any probe.
  test "chunk mode writes no probe" do
    Dir.mktmpdir do |d|
      LibraryBackendCheck.check!(backend: "chunk", env: { "LIBRARY_PATH" => d })
      assert_equal [], Dir.children(d)
    end
  end

  # A leaked probe is invisible to the scan, so it can never become a ghost node the reconciler
  # cannot pair. This pins the NAME, which is the whole mechanism: the Scanner skips TEMP_PREFIX
  # at every depth, and a probe that did not carry it would be indexed by a scan racing this
  # microsecond-wide window and then vanish — Task 2's permanent wedge, reached by a new road.
  # Pins the probe's NAME, which is a correctness property rather than cosmetics: the Scanner skips
  # TEMP_PREFIX at every depth, so a probe carrying it is invisible to a scan that races this
  # window. A probe that did NOT would be observed mid-flight, indexed, and then vanish on unlink —
  # an unpairable ghost whose tombstone trips the mass-deletion guard and wedges the library
  # permanently. That is Task 2's wedge reached by a new road; see Library::Scanner::TEMP_PREFIX.
  #
  # Reads the name out of the REAL EACCES, which names the path it could not create ("Permission
  # denied @ rb_sysopen - /…/.maker-tmp-…"). A successful probe is unlinked before it can be
  # observed, and minitest 6 has no bundled `stub` to suppress that — so the failing path is the
  # only place the true filename is visible without inventing a seam for the test to hold.
  test "the probe is named so a racing scan skips it" do
    skip "root bypasses permission bits: the probe succeeds and names nothing" if Process.uid.zero?
    Dir.mktmpdir do |d|
      File.chmod(0o500, d)
      begin
        err = assert_raises(LibraryBackendCheck::Error) do
          LibraryBackendCheck.check!(backend: "share", env: { "LIBRARY_PATH" => d })
        end
        assert_match(/#{Regexp.escape(File.join(d, Library::Scanner::TEMP_PREFIX))}/, err.message,
                     "a probe the Scanner does not skip is a ghost node waiting for a scan to race it")
      ensure
        File.chmod(0o755, d)
      end
    end
  end

  test "share mode boots on a real directory" do
    Dir.mktmpdir { |d| assert_nothing_raised { LibraryBackendCheck.check!(backend: "share", env: { "LIBRARY_PATH" => d }) } }
  end

  # An unmounted share is a real, readable, EMPTY directory, so the boot guard CANNOT see it and
  # must not try: an empty root is also a brand-new library, which is legitimate. Emptiness is
  # FileLayer::Share#library_present?'s signal at read time, where the answer can be retryable.
  test "an empty root boots — emptiness is not the boot guard's question" do
    Dir.mktmpdir { |d| assert_nothing_raised { LibraryBackendCheck.check!(backend: "share", env: { "LIBRARY_PATH" => d }) } }
  end

  # Both defaults, not just the backend: assert the raise with LIBRARY_PATH unset AND the pass
  # with it set. Without the second half, `env:`'s default could read any variable name at all
  # and this test — the one that names the claim — would stay green.
  #
  # This is the ONE test that exercises the real process ENV, and that is deliberate: every other
  # test injects `env:` a Hash, so nothing else here would notice if the default stopped being
  # ENV itself.
  test "defaults read the same ENV the factory reads" do
    prior_backend = ENV["LIBRARY_BACKEND"]
    prior_path = ENV["LIBRARY_PATH"]
    ENV["LIBRARY_BACKEND"] = "share"
    ENV["LIBRARY_PATH"] = nil
    assert_raises(LibraryBackendCheck::Error) { LibraryBackendCheck.check! }

    Dir.mktmpdir do |dir|
      ENV["LIBRARY_PATH"] = dir
      assert_nothing_raised { LibraryBackendCheck.check! }
    end
  ensure
    ENV["LIBRARY_BACKEND"] = prior_backend
    ENV["LIBRARY_PATH"] = prior_path
  end

  # --- s3 (phase 3) --------------------------------------------------------------------------

  S3_ENV = {
    "LIBRARY_S3_BUCKET" => "b", "LIBRARY_S3_ACCESS_KEY_ID" => "ak",
    "LIBRARY_S3_SECRET_ACCESS_KEY" => "sk", "LIBRARY_S3_REGION" => "us-east-1"
  }.freeze

  test "s3 mode refuses to boot without a bucket" do
    err = assert_raises(LibraryBackendCheck::Error) do
      LibraryBackendCheck.check!(backend: "s3", env: S3_ENV.except("LIBRARY_S3_BUCKET"))
    end
    assert_match(/LIBRARY_S3_BUCKET/, err.message, "the operator must be told WHICH knob is missing")
  end

  test "s3 mode names every missing knob at once, not one per restart" do
    err = assert_raises(LibraryBackendCheck::Error) { LibraryBackendCheck.check!(backend: "s3", env: {}) }
    %w[LIBRARY_S3_BUCKET LIBRARY_S3_ACCESS_KEY_ID LIBRARY_S3_SECRET_ACCESS_KEY].each do |knob|
      assert_match(/#{knob}/, err.message,
                   "a boot guard that reveals one missing knob per restart is a bad guard")
    end
  end

  # A knob set to "" or "   " is the SAME operator error as an unset one — a blank line in a .env
  # or a shell variable that expanded to nothing. Presence, not key-existence: `env.key?` would
  # call an empty bucket configured and hand the SDK "" to fail on later, naming nothing. This is
  # the share leg's `path.blank?` rule, applied to the same class of mistake.
  test "s3 mode treats a blank knob as missing rather than as configured" do
    err = assert_raises(LibraryBackendCheck::Error) do
      LibraryBackendCheck.check!(backend: "s3", env: S3_ENV.merge("LIBRARY_S3_BUCKET" => "   "))
    end
    assert_match(/LIBRARY_S3_BUCKET/, err.message)
  end

  test "s3 mode boots with the required knobs" do
    assert_nothing_raised { LibraryBackendCheck.check!(backend: "s3", env: S3_ENV) }
  end

  # REGION is NOT required: it defaults to "auto" (R2's value, matching Storage::S3ChunkStore's
  # own default). Verified against the real SDK: Aws::S3::Client.new(region: "auto") constructs
  # fine, while region: nil raises Aws::Errors::MissingRegionError — so the default is what keeps
  # an unset REGION from becoming a bare SDK error naming none of our knobs.
  test "s3 mode boots without a region — it defaults rather than being required" do
    assert_nothing_raised do
      LibraryBackendCheck.check!(backend: "s3", env: S3_ENV.except("LIBRARY_S3_REGION"))
    end
  end

  # The s3 guard must NOT reach the network. The share guard probes a real write because
  # File.writable? lies under NFS/SMB ACLs — but a boot guard that does a live S3 round-trip makes
  # the app's boot depend on a third party being up, and turns a transient blip into a crash loop.
  # Config presence is what boot can honestly check; credential validity surfaces on first use as
  # a FetchError, which is retryable BY DESIGN.
  #
  # 127.0.0.1:1 is a closed port: if this guard ever grew a HEAD/ListBuckets probe, the connection
  # is REFUSED immediately and this test fails loudly rather than hanging on a timeout.
  test "the s3 guard does not touch the network" do
    assert_nothing_raised do
      LibraryBackendCheck.check!(backend: "s3", env: S3_ENV.merge(
        "LIBRARY_S3_BUCKET" => "definitely-not-a-real-bucket-#{SecureRandom.hex(6)}",
        "LIBRARY_S3_ENDPOINT" => "http://127.0.0.1:1"
      ))
    end
  end

  # s3 mode must not touch the FILESYSTEM either: LIBRARY_PATH is the share's knob, and a guard
  # that probed a path in s3 mode would refuse to boot a perfectly good bucket over a variable
  # that means nothing to it.
  test "s3 mode writes no probe and ignores LIBRARY_PATH" do
    Dir.mktmpdir do |d|
      assert_nothing_raised do
        LibraryBackendCheck.check!(backend: "s3", env: S3_ENV.merge("LIBRARY_PATH" => d))
      end
      assert_equal [], Dir.children(d)
    end
  end
end
