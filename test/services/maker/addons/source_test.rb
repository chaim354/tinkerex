require "test_helper"

module Maker
  module Addons
    class SourceTest < ActiveSupport::TestCase
      setup do
        @prior_url = ENV["ADDON_SOURCE_URL"]
        @prior_path = ENV["ADDON_SOURCE_PATH"]
        ENV["ADDON_SOURCE_URL"] = "http://addons.test"
        # Cleared explicitly, not just left to whatever the process happened to have: this suite
        # also exercises ADDON_SOURCE_PATH below, and a value leaking in from another test in the
        # same parallel worker must not make an unrelated assertion here pass for the wrong reason.
        ENV.delete("ADDON_SOURCE_PATH")
      end

      teardown do
        ENV["ADDON_SOURCE_URL"] = @prior_url
        ENV["ADDON_SOURCE_PATH"] = @prior_path
        Source.reset!
      end

      test "configured? follows ADDON_SOURCE_URL" do
        assert Source.configured?
        ENV.delete("ADDON_SOURCE_URL")
        assert_not Source.configured?
      end

      test "configured? also follows ADDON_SOURCE_PATH" do
        ENV.delete("ADDON_SOURCE_URL")
        assert_not Source.configured?
        ENV["ADDON_SOURCE_PATH"] = "/tmp/nonexistent-addon-source"
        assert Source.configured?
      end

      test "current prefers Local over HTTP when ADDON_SOURCE_PATH is set alongside ADDON_SOURCE_URL" do
        # Both set is not a real deployment shape, but PATH winning is the safer failure mode: a
        # stray ADDON_SOURCE_URL left in the environment can never make a dev/test run hit the
        # network by surprise.
        ENV["ADDON_SOURCE_PATH"] = "/tmp/nonexistent-addon-source"
        assert_instance_of Source::Local, Source.current
      end

      test "current returns the HTTP source when only ADDON_SOURCE_URL is set" do
        assert_instance_of Source, Source.current
      end

      test "asset_path! rejects traversal instead of normalizing it" do
        # REJECTS, never normalizes — the same rule as FileLayer::S3#key_for (§14a). expand_path
        # would turn "a/../../b" into a VALID path and silently fetch the wrong object.
        %w[../secret a/../../etc/passwd /abs .. a/./b].each do |bad|
          assert_raises(Source::Error, "expected #{bad.inspect} to be refused") do
            Source.new("http://addons.test").asset_path!(bad)
          end
        end
      end

      # A NUL has no `/` and no `..`, so it rode through every refusal above — and then Pathname raised
      # ArgumentError: a backtrace from addons:check, and a 500 from Source::Local in dev.
      test "asset_path! refuses a NUL byte" do
        error = assert_raises(Source::Error) { Source.new("http://addons.test").asset_path!("a\u0000b.js") }
        assert_includes error.message, "NUL byte refused"
        Dir.mktmpdir do |dir|
          assert_raises(Source::Error) { Source::Local.new(dir).asset("generators", "a\u0000b.js") }
        end
      end

      test "asset_path! accepts an ordinary nested path" do
        source = Source.new("http://addons.test")
        assert_equal "generators/makerjs.js", source.asset_path!("generators/makerjs.js")
      end

      # THE HTTP SOURCE ONLY — WHICH IS PRECISELY WHY THIS WAS GREEN FOR MONTHS OVER A LIVE 500.
      # validate_asset_path! rejects traversal, absolute paths, empty segments and NULs; it does NOT
      # reject spaces, newlines or non-ASCII, all of which make URI.parse raise. Source::Local
      # (the dev/test default) reads with Pathname#read and never parses a URI, so the entire suite
      # ran past a condition only the production code path can reach — the same shape as §14a's
      # STORAGE_BACKEND 500, a guard whose precondition is never established in test. These
      # construct the HTTP Source explicitly for that reason.
      #
      # NO SERVER IS NEEDED and none is started: URI.parse raises on the FIRST line of #get, long
      # before any socket. A test that needed a listener would be testing something else.
      test "an asset path URI.parse cannot handle is Source::Error (a 404), not a bare 500" do
        [ "a b.js", "café.js", "a\nb.js" ].each do |bad|
          error = assert_raises(Source::Error, "expected #{bad.inspect} to be a routine refusal") do
            Source.new("http://addons.test").asset("widgetkit", bad)
          end
          assert_includes error.message, "InvalidURIError",
                          "the refusal should still name the real cause for an operator"
        end
      end

      # The complement, and the reason the one above cannot pass vacuously: an ordinary name must
      # still get as far as the network (here: a connection refusal), not be swallowed by the new
      # rescue arm. Port 1 is closed, so this proves the path reached Net::HTTP.
      test "an ordinary asset path still reaches the network rather than failing URI parsing" do
        error = assert_raises(Source::Error) { Source.new("http://127.0.0.1:1").asset("widgetkit", "ok.js") }
        assert_not_includes error.message, "InvalidURIError"
      end

      test "a malformed manifest index raises Source::Error, not a JSON error" do
        source = Source.new("http://addons.test")
        # NOT Object#stub: minitest 6 dropped minitest/mock in this repo (`require "minitest/mock"`
        # is a LoadError — verified directly, and test_helper.rb's with_concurrent_file_attachment
        # comment says the same). `get` is private, but define_singleton_method reaches it fine —
        # it defines straight onto the instance's singleton class, same as any other private method.
        source.define_singleton_method(:get) { |*_args| "not json at all" }
        assert_raises(Source::Error) { source.manifests }
      end

      # Source::Local — the dev/test-only filesystem-backed mode (ADDON_SOURCE_PATH). Same public
      # interface as the HTTP Source, so Registry and Tools::AddonsController don't branch on which
      # one they got; these tests hold Local to the exact same contract the tests above hold Source
      # to, one behaviour at a time.
      test "Local#manifests reads manifests.json off disk" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "manifests.json"), [ { "key" => "x" } ].to_json)
          assert_equal [ { "key" => "x" } ], Source::Local.new(dir).manifests
        end
      end

      test "Local#manifests raises Source::Error on malformed JSON, not a JSON error" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "manifests.json"), "not json at all")
          assert_raises(Source::Error) { Source::Local.new(dir).manifests }
        end
      end

      test "Local#manifests raises Source::Error when the index isn't an array" do
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "manifests.json"), {}.to_json)
          assert_raises(Source::Error) { Source::Local.new(dir).manifests }
        end
      end

      test "Local#manifests raises Source::Error, not Errno, when the file is missing" do
        Dir.mktmpdir do |dir|
          assert_raises(Source::Error) { Source::Local.new(dir).manifests }
        end
      end

      # Root reads a mode-000 file anyway, so there the precondition cannot be established — skipped,
      # rather than passing for a reason that has nothing to do with the rescue.
      test "Local#manifests raises Source::Error, not Errno, when the file is unreadable" do
        skip "running as root, where a mode-000 file is still readable" if Process.euid.zero?

        Dir.mktmpdir do |dir|
          index = File.join(dir, "manifests.json")
          File.write(index, "[]")
          File.chmod(0o000, index)
          error = assert_raises(Source::Error) { Source::Local.new(dir).manifests }
          assert_includes error.message, "EACCES"
        ensure
          File.chmod(0o644, index) if index && File.exist?(index)
        end
      end

      test "Local#asset reads a file's bytes off disk" do
        Dir.mktmpdir do |dir|
          FileUtils.mkdir_p(File.join(dir, "generators"))
          File.write(File.join(dir, "generators", "x.js"), "hello")
          assert_equal "hello", Source::Local.new(dir).asset("generators", "x.js")
        end
      end

      test "Local#asset raises Source::Error, not Errno, for a missing file" do
        Dir.mktmpdir do |dir|
          assert_raises(Source::Error) { Source::Local.new(dir).asset("generators", "nope.js") }
        end
      end

      test "Local#asset rejects traversal exactly like the HTTP source" do
        Dir.mktmpdir do |dir|
          %w[../secret a/../../etc/passwd /abs .. a/./b].each do |bad|
            assert_raises(Source::Error, "expected #{bad.inspect} to be refused") do
              Source::Local.new(dir).asset("generators", bad)
            end
          end
        end
      end

      # A STRONGER traversal test than the one above, and the one that actually mutation-checks: for
      # the HTTP source, `..` in a URL path just names a route nothing answers, so any raise proves
      # the guard did something. `Local` hits REAL disk — `Pathname#join` does not sanitize `..`, the
      # OS resolves it at open time — so a naive traversal test can go green FOR THE WRONG REASON: a
      # first attempt at this test used a made-up escape target that simply didn't exist on disk,
      # which raised Errno::ENOENT (also rescued into Source::Error) whether or not the guard ran at
      # all — removing `Source.validate_asset_path!` from Local#asset left every test in this file
      # green. This one plants a REAL file just outside the source root and proves it is actually
      # unreachable, not merely coincidentally missing.
      test "Local#asset cannot read a real file outside the source root" do
        Dir.mktmpdir do |parent|
          root = File.join(parent, "addons")
          FileUtils.mkdir_p(File.join(root, "generators"))
          File.write(File.join(parent, "secret.txt"), "PWNED")

          assert_raises(Source::Error) { Source::Local.new(root).asset("generators", "../../secret.txt") }
        end
      end
    end
  end
end
