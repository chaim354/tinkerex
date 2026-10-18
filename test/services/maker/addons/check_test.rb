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

      # ROOT is PARENT/addons, so PARENT is "outside PATH" — where the escape tests below PLANT their
      # targets, so that "refused" can never be confused with "happened not to exist".
      def with_parent
        Dir.mktmpdir do |parent|
          parent = Pathname.new(parent)
          yield parent.join("addons").tap(&:mkpath), parent
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

      # A KEY IS ONE URL SEGMENT AND ONE FOLDER NAME (/tools/:key), and Registry does not refuse one
      # that isn't. Each escape below has the addon's files PLANTED where the join would land, so an
      # empty result can only mean the key was never joined. The nested key has nothing planted: it is
      # the case that shows the files are not checked at all (one problem, not "no <key>/ directory").
      test "a key that is not a single path segment is reported and its files are not checked" do
        with_parent do |root, parent|
          [ root, parent, parent.join("outside/addondir") ].each do |dir|
            dir.mkpath
            %w[widget.js dep.js].each { |f| dir.join(f).write("") }
          end

          [ "../outside/addondir", parent.join("outside/addondir").to_s, "..", ".", "nested/widget", "wid\u0000get" ].each do |key|
            root.join("manifests.json").write(JSON.generate([ MANIFEST.merge("key" => key) ]))
            assert_equal [ { key:, reason: "key must be a single path segment (it becomes /tools/<key> and the <key>/ folder)" } ],
                         Check.run(root).problems, "key #{key.inspect}"
          end
        end
      end

      # DOCKER'S COPY CARRIES A SYMLINK AS A SYMLINK, so one resolving outside PATH dangles in the addons
      # image and the host 404s a file this check saw. Every target is a REAL, planted file or folder.
      test "an addon directory that is a symlink resolving outside PATH is reported once" do
        with_parent do |root, parent|
          parent.join("elsewhere").mkpath
          %w[widget.js dep.js].each { |f| parent.join("elsewhere", f).write("") }
          root.join("manifests.json").write(JSON.generate([ MANIFEST ]))
          root.join("widget").make_symlink(parent.join("elsewhere"))

          assert_equal [ { key: "widget", reason: "widget/ resolves outside #{root} (a symlink the image would not carry)" } ],
                       Check.run(root).problems
        end
      end

      test "an entry or pin that is a symlink resolving outside PATH is reported" do
        with_parent do |root, parent|
          parent.join("outside.js").write("")
          root.join("manifests.json").write(JSON.generate([ MANIFEST ]))
          root.join("widget").mkpath
          root.join("widget/widget.js").make_symlink(parent.join("outside.js"))
          root.join("widget/dep.js").make_symlink("../../outside.js") # relative, and still outside

          assert_equal [
            { key: "widget", reason: "entry: widget.js resolves outside #{root} (a symlink the image would not carry)" },
            { key: "widget", reason: %(pin "dep": dep.js resolves outside #{root} (a symlink the image would not carry)) }
          ], Check.run(root).problems
        end
      end

      # The complement, so the two above cannot pass by refusing every symlink — and, on macOS, by
      # comparing against an unresolved PATH (Dir.mktmpdir's /var is itself a link to /private/var).
      test "a symlinked addon directory or entry that resolves inside PATH is fine" do
        with_parent do |root, _parent|
          root.join("manifests.json").write(JSON.generate([ MANIFEST ]))
          root.join("real-widget").mkpath
          root.join("shared").mkpath
          root.join("shared/widget.js").write("")
          root.join("real-widget/dep.js").write("")
          root.join("real-widget/widget.js").make_symlink("../shared/widget.js")
          root.join("widget").make_symlink("real-widget")

          assert_equal [], Check.run(root).problems
        end
      end

      # Pathname raises ArgumentError on a NUL; Source.validate_asset_path! refuses it first.
      test "a NUL byte in an entry or pin is reported, not raised" do
        with_addons([ MANIFEST.merge("entry" => "wid\u0000get.js", "pins" => { "dep" => "d\u0000ep.js" }) ]) do |root|
          problems = Check.run(root).problems
          assert_equal %w[widget widget], problems.pluck(:key)
          assert_match(/\Aentry: .* is not a safe path \(NUL byte refused/, problems[0][:reason])
          assert_match(/\Apin "dep": .* is not a safe path \(NUL byte refused/, problems[1][:reason])
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
