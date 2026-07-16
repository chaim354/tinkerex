require "test_helper"
require "tmpdir"

class LibraryBackendCheckTest < ActiveSupport::TestCase
  test "chunk mode needs no library path" do
    assert_nothing_raised { LibraryBackendCheck.check!(backend: "chunk", path: nil) }
  end

  test "share mode refuses to boot without a path" do
    err = assert_raises(LibraryBackendCheck::Error) do
      LibraryBackendCheck.check!(backend: "share", path: nil)
    end
    assert_match(/requires LIBRARY_PATH/, err.message)
  end

  test "share mode refuses to boot on a blank path" do
    assert_raises(LibraryBackendCheck::Error) { LibraryBackendCheck.check!(backend: "share", path: "  ") }
  end

  test "share mode refuses to boot on a missing root" do
    err = assert_raises(LibraryBackendCheck::Error) do
      LibraryBackendCheck.check!(backend: "share", path: "/nonexistent-#{SecureRandom.hex(4)}")
    end
    assert_match(/does not exist/, err.message,
                 "must name the actual problem — a path that is not there is a typo'd " \
                 "LIBRARY_PATH, NOT an unmounted share (an unmounted share exists and is empty)")
  end

  test "share mode refuses to boot when the root is a file rather than a directory" do
    Tempfile.create("library") do |f|
      err = assert_raises(LibraryBackendCheck::Error) do
        LibraryBackendCheck.check!(backend: "share", path: f.path)
      end
      assert_match(/not a directory/, err.message)
    end
  end

  test "share mode refuses to boot on an unreadable root" do
    Dir.mktmpdir do |dir|
      File.chmod(0o000, dir)
      skip "running as root: an unreadable directory is still readable" if File.readable?(dir)
      err = assert_raises(LibraryBackendCheck::Error) do
        LibraryBackendCheck.check!(backend: "share", path: dir)
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
          LibraryBackendCheck.check!(backend: "share", path: d)
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
      LibraryBackendCheck.check!(backend: "share", path: d)
      assert_equal [], Dir.children(d), "the probe must clean up after itself"
    end
  end

  # Chunk mode must not touch the filesystem at all — the guard returns before any probe.
  test "chunk mode writes no probe" do
    Dir.mktmpdir do |d|
      LibraryBackendCheck.check!(backend: "chunk", path: d)
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
          LibraryBackendCheck.check!(backend: "share", path: d)
        end
        assert_match(/#{Regexp.escape(File.join(d, Library::Scanner::TEMP_PREFIX))}/, err.message,
                     "a probe the Scanner does not skip is a ghost node waiting for a scan to race it")
      ensure
        File.chmod(0o755, d)
      end
    end
  end

  test "share mode boots on a real directory" do
    Dir.mktmpdir { |d| assert_nothing_raised { LibraryBackendCheck.check!(backend: "share", path: d) } }
  end

  # An unmounted share is a real, readable, EMPTY directory, so the boot guard CANNOT see it and
  # must not try: an empty root is also a brand-new library, which is legitimate. Emptiness is
  # FileLayer::Share#library_present?'s signal at read time, where the answer can be retryable.
  test "an empty root boots — emptiness is not the boot guard's question" do
    Dir.mktmpdir { |d| assert_nothing_raised { LibraryBackendCheck.check!(backend: "share", path: d) } }
  end

  # Both defaults, not just the backend: assert the raise with LIBRARY_PATH unset AND the pass
  # with it set. Without the second half, `path:`'s default could read any variable name at all
  # and this test — the one that names the claim — would stay green.
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
end
