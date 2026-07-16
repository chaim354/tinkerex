require "test_helper"
require "tmpdir"

module FileLayer
  class FactoryTest < ActiveSupport::TestCase
    setup { FileLayer.reset! }
    teardown { FileLayer.reset! }

    # "Defaults" means LIBRARY_BACKEND is UNSET — so unset it. Reading the ambient process ENV
    # made this test assert whatever the environment happened to say, which is not the claim in
    # its name: under LIBRARY_BACKEND=share it failed while the default was still perfectly fine.
    test "defaults to the chunk adapter when LIBRARY_BACKEND is unset" do
      with_backend(nil) { assert_instance_of FileLayer::Chunk, FileLayer.current }
    end

    test "LIBRARY_BACKEND=chunk selects the chunk adapter" do
      with_backend("chunk") { assert_instance_of FileLayer::Chunk, FileLayer.current }
    end

    test "an unknown backend refuses to build rather than silently defaulting" do
      with_backend("nope") do
        assert_raises(ArgumentError) { FileLayer.current }
      end
    end

    test "LIBRARY_BACKEND=share selects the Share adapter" do
      Dir.mktmpdir do |dir|
        with_backend("share") do
          with_library_path(dir) { assert_instance_of FileLayer::Share, FileLayer.current }
        end
      end
    end

    # Share.new defaults to ENV.fetch("LIBRARY_PATH"), which raises a bare KeyError. The factory
    # must answer with the same explanation the boot guard gives, because the boot guard is
    # skipped in the test env and reads ENV only once at boot: a LIBRARY_PATH that is unset (or
    # changed) after boot must still fail with "share requires LIBRARY_PATH", not KeyError.
    test "LIBRARY_BACKEND=share without LIBRARY_PATH explains itself rather than raising KeyError" do
      with_backend("share") do
        with_library_path(nil) do
          err = assert_raises(LibraryBackendCheck::Error) { FileLayer.current }
          assert_match(/requires LIBRARY_PATH/, err.message,
                       "must name the missing setting, not incidentally fail some other way")
        end
      end
    end

    # s3 is Phase 3. Until then an operator setting it must get a loud error, never a silent
    # fallback to chunk mode (which would read the WRONG library).
    test "s3 is not yet implemented and says so" do
      with_backend("s3") do
        err = assert_raises(NotImplementedError) { FileLayer.current }
        assert_match(/s3/, err.message)
      end
    end

    # Pinned rather than ambient: memoization is backend-agnostic, so the backend should be the
    # test's choice, not the environment's.
    test "current is memoized and reset! clears it" do
      with_backend("chunk") do
        first = FileLayer.current
        assert_same first, FileLayer.current
        FileLayer.reset!
        assert_not_same first, FileLayer.current
      end
    end

    def with_backend(value)
      prior = ENV["LIBRARY_BACKEND"]
      ENV["LIBRARY_BACKEND"] = value
      FileLayer.reset!
      yield
    ensure
      ENV["LIBRARY_BACKEND"] = prior
      FileLayer.reset!
    end

    # Nil means "unset it" — ENV["X"] = nil deletes the key, which is exactly the
    # operator-forgot-to-set-it case the factory has to explain.
    def with_library_path(value)
      prior = ENV["LIBRARY_PATH"]
      ENV["LIBRARY_PATH"] = value
      FileLayer.reset!
      yield
    ensure
      ENV["LIBRARY_PATH"] = prior
      FileLayer.reset!
    end
  end
end
