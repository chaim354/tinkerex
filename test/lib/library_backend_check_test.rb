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
