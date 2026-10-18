require "test_helper"

module Maker
  module Addons
    # Maker::Addons::Check reads a REAL directory through Source::Local — the same reader dev uses —
    # so each test writes one. Never a fake source: the on-disk checks are the point.
    class CheckTest < ActiveSupport::TestCase
      MANIFEST = {
        "key" => "widget", "title" => "Widget", "icon" => "🛠️", "description" => "Makes widgets",
        "api_version" => "1", "entry" => "widget.js", "pins" => { "dep" => "dep.js" }
      }.freeze

      def with_addons(manifests, files: { "widget/widget.js" => "", "widget/dep.js" => "" })
        Dir.mktmpdir do |root|
          root = Pathname.new(root)
          root.join("manifests.json").write(JSON.generate(manifests))
          files.each do |rel, body|
            root.join(rel).dirname.mkpath
            root.join(rel).write(body)
          end
          yield root
        end
      end

      test "a clean directory is OK and counts its manifests" do
        with_addons([ MANIFEST ]) do |root|
          result = Check.run(root)
          assert result.ok?
          assert_equal 1, result.count
          assert_equal [], result.problems
        end
      end

      test "a manifest the registry would skip is reported with the registry's own reason" do
        with_addons([ MANIFEST.except("title") ]) do |root|
          assert_equal [ { key: "widget", reason: "missing title" } ], Check.run(root).problems
        end
      end

      test "a missing entry file is reported" do
        with_addons([ MANIFEST ], files: { "widget/dep.js" => "" }) do |root|
          assert_equal [ { key: "widget", reason: "entry: widget.js does not exist" } ], Check.run(root).problems
        end
      end

      test "a missing pinned file is reported, naming the specifier" do
        with_addons([ MANIFEST ], files: { "widget/widget.js" => "" }) do |root|
          assert_equal [ { key: "widget", reason: %(pin "dep": dep.js does not exist) } ], Check.run(root).problems
        end
      end

      test "a missing addon directory is reported once, not once per file" do
        with_addons([ MANIFEST ], files: {}) do |root|
          assert_equal [ { key: "widget", reason: "no widget/ directory beside manifests.json" } ],
                       Check.run(root).problems
        end
      end

      # REJECTED, NEVER RESOLVED (§14a's key_for rule, via Source.validate_asset_path!). The escape
      # target is PLANTED, so "refused" cannot be confused with "happened not to exist" — the
      # false-green shape docs/invariants/addons.md records for Source::Local's own test.
      test "a traversing entry is reported as unsafe, even when the target exists" do
        with_addons([ MANIFEST.merge("entry" => "../escape.js") ],
                    files: { "widget/dep.js" => "", "escape.js" => "" }) do |root|
          problem = Check.run(root).problems.sole
          assert_equal "widget", problem[:key]
          assert_match(/\Aentry: \.\.\/escape\.js is not a safe path/, problem[:reason])
        end
      end

      test "a directory with no manifests.json raises Source::Error naming it" do
        Dir.mktmpdir do |root|
          error = assert_raises(Source::Error) { Check.run(root) }
          assert_match(/manifests\.json/, error.message)
        end
      end

      test "a path that is not a directory raises Source::Error naming it" do
        error = assert_raises(Source::Error) { Check.run("/nonexistent/addons") }
        assert_match(%r{/nonexistent/addons is not a directory}, error.message)
      end
    end
  end
end
