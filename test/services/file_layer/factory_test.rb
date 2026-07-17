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

    S3_ENV = {
      "LIBRARY_S3_BUCKET" => "b", "LIBRARY_S3_ACCESS_KEY_ID" => "ak",
      "LIBRARY_S3_SECRET_ACCESS_KEY" => "sk", "LIBRARY_S3_REGION" => "us-east-1"
    }.freeze

    test "LIBRARY_BACKEND=s3 selects the S3 adapter" do
      with_backend("s3") do
        with_env(S3_ENV) { assert_instance_of FileLayer::S3, FileLayer.current }
      end
    end

    # The same contract the share leg has, and for a sharper reason: S3.from_env's ENV.fetch would
    # raise KeyError naming ONE knob, so an operator who set none would learn them one restart at
    # a time. The guard names them all at once — the factory must ask it BEFORE constructing, or
    # that message is unreachable in the test env (where the boot guard is skipped) and after any
    # post-boot ENV change.
    test "LIBRARY_BACKEND=s3 without credentials explains itself rather than raising KeyError" do
      with_backend("s3") do
        with_env(S3_ENV.transform_values { nil }) do
          err = assert_raises(LibraryBackendCheck::Error) { FileLayer.current }
          assert_match(/LIBRARY_S3_BUCKET/, err.message,
                       "must name the missing settings, not incidentally fail some other way")
          assert_match(/LIBRARY_S3_SECRET_ACCESS_KEY/, err.message)
        end
      end
    end

    # Constructing the adapter must not reach the network either — the factory runs at boot.
    test "building the S3 adapter does not require the bucket to be reachable" do
      assert_nothing_raised do
        FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                          secret_access_key: "sk", endpoint: "http://127.0.0.1:1")
      end
    end

    # The counterexample this whole adapter is, stated as an assertion. Every OTHER backend has
    # presignable == versioned (chunk true/true, share false/false), so a reader could reasonably
    # conclude the two co-vary and "simplify" one into the other. S3 is why they cannot: it holds
    # the user's own bytes with no history (spec decision 3 — §5 does not survive), yet it CAN
    # mint a URL (§15 survives, which is what Phase 4's Redirect is built on).
    test "S3 is presignable but NOT versioned — the pair does not co-vary" do
      caps = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                               secret_access_key: "sk").capabilities
      assert caps.presignable?, "S3 can mint a URL: §15 survives here"
      assert_not caps.versioned?, "S3 keeps no history: §5 does not survive here"
      assert_not caps.syncable?
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
    def with_library_path(value, &block)
      with_env({ "LIBRARY_PATH" => value }, &block)
    end

    # with_library_path generalized to N knobs, because s3 has five. Same nil-means-unset rule,
    # and the same restore-the-prior discipline: the factory reads the PROCESS ENV, so these
    # tests must mutate it — and a leak would silently reconfigure the next test in this worker.
    def with_env(vars)
      prior = vars.keys.to_h { |k| [ k, ENV[k] ] }
      vars.each { |k, v| ENV[k] = v }
      FileLayer.reset!
      yield
    ensure
      prior.each { |k, v| ENV[k] = v }
      FileLayer.reset!
    end
  end
end
