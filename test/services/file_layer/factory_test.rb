require "test_helper"
require "tmpdir"
require "prism"

module FileLayer
  class FactoryTest < ActiveSupport::TestCase
    setup { FileLayer.reset! }
    teardown { FileLayer.reset! }

    # "Defaults" means LIBRARY_BACKEND is UNSET — so unset it. Reading the ambient process ENV
    # made this test assert whatever the environment happened to say, which is not the claim in
    # its name: under LIBRARY_BACKEND=share it failed while the default was still perfectly fine.
    # THE DEFAULT IS share, AND IT USED TO BE chunk. Embedded chunk was retired in Arc D Part 2,
    # so the old default named an adapter that no longer exists — every context that did not set
    # LIBRARY_BACKEND got NameError from inside FileLayer.build, several frames from anything that
    # mentioned a backend. share is the only HERMETIC backend left (chunk_remote resolves against a
    # standalone sync server), and nothing in production depends on this either way since all Kamal
    # destinations set LIBRARY_BACKEND explicitly.
    test "defaults to the share adapter when LIBRARY_BACKEND is unset" do
      Dir.mktmpdir do |dir|
        with_backend(nil) do
          with_library_path(dir) { assert_instance_of FileLayer::Share, FileLayer.current }
        end
      end
    end

    # `chunk` IS NOW AN UNKNOWN BACKEND, and this asserts that it is REFUSED rather than quietly
    # treated as an alias for chunk_remote. A deployment still carrying LIBRARY_BACKEND=chunk is
    # misconfigured — its library lives on a sync server it has not been pointed at — and silently
    # serving it a different backend would hand it an empty library that looks like data loss.
    test "LIBRARY_BACKEND=chunk is refused now that embedded chunk is retired" do
      with_backend("chunk") do
        assert_raises(ArgumentError) { FileLayer.current }
      end
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

    # THE DEFAULT ARM MUST ASK THE GUARD TOO, and until 2026-08-26 it did not. This is the same
    # claim as the test above with LIBRARY_BACKEND *unset* — the one configuration a fresh clone
    # actually has — and that one word is the whole difference: `build` resolved "share" and then
    # called `LibraryBackendCheck.check!` with NO ARGUMENTS, so the guard re-read ENV with ITS OWN
    # default (`chunk`, the value Arc D Part 2 retired and `build` itself refuses), matched no arm,
    # and returned having checked nothing. `Share.new`'s `ENV.fetch("LIBRARY_PATH")` then raised a
    # bare KeyError naming no setting. THE ONE BACKEND REACHABLE WITHOUT SETTING LIBRARY_BACKEND
    # WAS THE ONE THE GUARD NEVER CHECKED.
    #
    # Neither existing test could catch it, and the pair is the §15 shape exactly: the one above
    # sets LIBRARY_BACKEND explicitly, and "defaults to the share adapter" supplies a valid
    # LIBRARY_PATH — so between them the default arm's guard has no test that establishes its
    # precondition. It surfaced as `bin/ci setup` failing on a clean clone, several frames away,
    # inside the PurgeRepoMetadataNodes migration.
    #
    # `check!` HAS NO DEFAULT SINCE 2026-10-19: the factory and the boot both hand it the name
    # LibraryBackendCheck.configured resolved, and unset is a state of its own rather than a value —
    # the factory builds share on it, the boot lets development start. Do not give check! a `share`
    # default to make the two agree: measured, that refused the boot of any dev box with nothing
    # configured, breaking `bin/setup` one step EARLIER rather than fixing it.
    test "the DEFAULT backend arm asks the guard, not just the explicit one" do
      with_backend(nil) do
        with_library_path(nil) do
          err = assert_raises(LibraryBackendCheck::Error) { FileLayer.current }
          assert_match(/requires LIBRARY_PATH/, err.message,
                       "the default arm must give the operator the same explanation the explicit one does")
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

    CHUNK_REMOTE_ENV = {
      "CHUNK_REMOTE_URL" => "http://sync.example", "SYNC_ADMIN_TOKEN" => "admin-token",
      "SYNC_PUBLIC_URL" => "http://sync.example.net"
    }.freeze

    # THE NAMES THE READING ACCEPTS AND THE ARMS OF build's `case` ARE ONE SET, pinned both ways. A
    # name with no arm would pass the boot (check! has nothing to check for it) and then raise out of
    # `else` on every response — the 500 the one reading exists to close. An arm with no name is dead
    # code no deployment can select. NAMES is the list; the `case` stays the factory.
    ADAPTER_FOR = { "share" => FileLayer::Share, "s3" => FileLayer::S3, "chunk_remote" => FileLayer::ChunkRemote }.freeze

    test "every name LibraryBackendCheck accepts builds its adapter" do
      assert_equal LibraryBackendCheck::NAMES.sort, ADAPTER_FOR.keys.sort,
                   "a name this test has no adapter for is a name it cannot prove the factory builds"
      Dir.mktmpdir do |dir|
        minimal = { "share" => { "LIBRARY_PATH" => dir }, "s3" => S3_ENV, "chunk_remote" => CHUNK_REMOTE_ENV }
        LibraryBackendCheck::NAMES.each do |name|
          with_backend(name) do
            with_env(minimal.fetch(name)) { assert_instance_of ADAPTER_FOR.fetch(name), FileLayer.build, name }
          end
        end
      end
    end

    test "build's case has one arm per known name, and no other" do
      assert_equal LibraryBackendCheck::NAMES.sort, factory_arms.sort
    end

    # Pinned rather than ambient: memoization is backend-agnostic, so the backend should be the
    # test's choice, not the environment's.
    test "current is memoized and reset! clears it" do
      Dir.mktmpdir do |dir|
        with_backend("share") do
          with_library_path(dir) do
            first = FileLayer.current
            assert_same first, FileLayer.current
            FileLayer.reset!
            assert_not_same first, FileLayer.current
          end
        end
      end
    end

    # The `when` labels of FileLayer.build's `case`, read by the parser Ruby ships rather than by a
    # regex over the file, so the answer is that method's arms and nothing else in file_layer.rb.
    def factory_arms
      path, line = FileLayer.method(:build).source_location
      build = Prism.parse_file(path).value.breadth_first_search { |node| node.is_a?(Prism::DefNode) && node.location.start_line == line }
      build.breadth_first_search { |node| node.is_a?(Prism::CaseNode) }.conditions.flat_map(&:conditions).map(&:unescaped)
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
