require "test_helper"

# Guards that every Stimulus controller a VIEW DECLARES actually exists as a controller file.
#
# WHY THIS NEEDS A TEST AT ALL: Stimulus resolves `data-controller="foo"` against the identifiers
# registered by `eagerLoadControllersFrom` (app/javascript/controllers/index.js), and an identifier
# that resolves to nothing is a SILENT NO-OP — nothing throws, nothing is logged, not even a console
# warning. The page renders perfectly and the feature is simply gone.
#
# THIS ALREADY HAPPENED, AND COST NINE DAYS. 6095b87 (2026-08-03, the Box Generator's migration to a
# runtime ESM bundle) deleted boxpreview_controller.js and boxfilter_controller.js while
# app/views/tools/openscad/ went on declaring both. The OpenSCAD editor opened on an empty grey
# preview panel and the generator filter did nothing. Every Ruby test stayed green — including
# test/controllers/tools/openscad_controller_test.rb, which POSTs the preview endpoint DIRECTLY and
# so could not notice that the only thing which issues that POST had become inert. That is this
# repo's recorded dominant failure shape (CLAUDE.md §15): a green suite over something that never
# runs. This test would have failed IN that commit.
#
# `data-controller` IS THE COMPLETE SET, not merely the convenient one to grep. Stimulus dispatches
# `data-action="x->foo#bar"` and binds `data-foo-target` only when `foo` is attached to an ancestor
# through `data-controller`, so a controller never named in a `data-controller` is unreachable by
# any other spelling. Sweeping this one attribute therefore misses nothing.
#
# DIRECTION IS DELIBERATE: declared-but-missing is a broken feature, so it fails. The converse —
# a controller file no view names — is NOT an error: hello_controller.js is Rails' scaffold, and
# thumbfallback_controller.js is reached from JS. A guard that also demanded the reverse would have
# to carry an exception list, which is the thing this file exists to avoid.
#
# Lives beside test/ci_hygiene_test.rb and test/deploy_hygiene_test.rb, for the same reason both of
# those exist: app/javascript/controllers/*.js are files the Rails process never loads, so no other
# test tier in this suite can see them.
class StimulusHygieneTest < ActiveSupport::TestCase
  CONTROLLERS_DIR = Rails.root.join("app/javascript/controllers")
  VIEWS_DIR = Rails.root.join("app/views")

  # The literal attribute, in either quoting style. ONE ATTRIBUTE MAY CARRY SEVERAL space-separated
  # identifiers (`data-controller="thumbs filemenu"` appears three times in app/views/files alone),
  # which is why the captured value is split rather than used whole — a sweep that took it whole
  # would look up "thumbs filemenu" as a single name and report both as missing.
  ATTRIBUTE_RE = /data-controller\s*=\s*(?<q>["'])(?<names>.*?)\k<q>/m

  # The Rails `data:` hash spelling. `tag.span data: { controller: "filechooser" }` emits exactly the
  # same attribute and app/views/shared/_folder_field.html.erb uses it, so a sweep for the literal
  # attribute alone would miss a real declaration — silently, which is this file's whole subject.
  #
  # ANCHORED ON `data:` so that a routing option (`url_for controller: "files"`) can never be
  # mistaken for a Stimulus identifier, and the intermediate tolerates ONE level of nested braces so
  # an interpolated sibling value (`"#{x}"`) doesn't end the scan before the key is reached. It
  # cannot escape the hash it started in: passing the closing `}` would need `[^{}]` to match a
  # brace, which it cannot.
  HASH_RE = /data:\s*\{(?:[^{}]|\{[^{}]*\})*?\bcontroller:\s*(?<q>["'])(?<names>[^"']*)\k<q>/m

  # THE IDENTIFIER RULE IS DERIVED, NOT LISTED — a new controller must need no edit to this file.
  #
  # Replicates `registerControllerFromPath` in @hotwired/stimulus-loading VERBATIM (the function
  # `eagerLoadControllersFrom` calls for every match), operating on the same input it does: the
  # importmap pin name, which `pin_all_from "app/javascript/controllers", under: "controllers"`
  # makes the extension-less path relative to that directory.
  #
  #   .replace("_controller", "")  -> `sub`, NOT `gsub`: JS's String#replace with a STRING argument
  #                                   replaces the FIRST occurrence only, and it runs BEFORE the
  #                                   underscore pass, so the order below is not interchangeable.
  #   .replace(/\//g, "--")        -> a subdirectory becomes a `--` namespace separator.
  #   .replace(/_/g,  "-")         -> snake_case becomes kebab-case (`file_menu` -> `file-menu`).
  def self.identifier_for(relative_path)
    relative_path.delete_suffix(".js").sub("_controller", "").gsub("/", "--").tr("_", "-")
  end

  # -> [[identifier, "path:line"], …] for one file's source. A class method so the test below can
  # feed it a synthetic document instead of whatever the repo happens to contain today.
  def self.declarations_in(source, label)
    [ ATTRIBUTE_RE, HASH_RE ].flat_map do |re|
      source.to_enum(:scan, re).map { Regexp.last_match }.flat_map do |m|
        line = source[0...m.begin(0)].count("\n") + 1
        m[:names].split(/\s+/).reject(&:empty?).map { |name| [ name, "#{label}:#{line}" ] }
      end
    end
  end

  # `eagerLoadControllersFrom` filters the importmap on /^controllers\/.*_controller$/, so a pinned
  # file NOT ending in `_controller.js` (application.js, index.js) is never registered as one.
  def registered_identifiers
    Dir.glob("**/*_controller.js", base: CONTROLLERS_DIR).map { |rel| self.class.identifier_for(rel) }
  end

  def view_declarations
    Dir.glob("**/*.erb", base: VIEWS_DIR).sort.flat_map do |rel|
      self.class.declarations_in(VIEWS_DIR.join(rel).read, "app/views/#{rel}")
    end
  end

  test "every Stimulus controller declared in a view resolves to a controller file" do
    known = registered_identifiers
    offenders = view_declarations.reject { |name, _where| known.include?(name) }

    assert_empty offenders.map { |name, where| "#{where} declares `#{name}`" },
                 "a view names a Stimulus controller that no file in app/javascript/controllers " \
                 "registers. Stimulus fails SILENTLY on an unresolvable identifier, so whatever " \
                 "that controller did is dead on that page with nothing in the console to say so " \
                 "— see this file's header. Registered: #{known.sort.join(' ')}"
  end

  # PROVES BOTH ARMS OF THE SWEEP CARRY WEIGHT, on a synthetic document rather than on whatever
  # app/views contains today. A regex that quietly stopped matching would otherwise leave the test
  # above passing because it finds nothing to check — the exact false green this file is about.
  # The last line is the anchor's own case: a routing `controller:` must NOT be collected.
  test "the sweep reads both spellings, splits multiple names, and ignores a routing option" do
    source = <<~'ERB'
      <div data-controller="alpha beta"></div>
      <span data-controller='gamma'></span>
      <%= tag.span data: { title: "#{x}", controller: "delta" } do %><% end %>
      <%= link_to "x", url_for(controller: "not_a_stimulus_identifier") %>
    ERB

    found = self.class.declarations_in(source, "synthetic")
    assert_equal %w[alpha beta gamma delta], found.map(&:first)
    # The location is what makes a failure actionable — "something, somewhere" is not a bug report.
    assert_equal %w[synthetic:1 synthetic:1 synthetic:2 synthetic:3], found.map(&:last)
  end

  # The mapping is derived by replicating a function in a JS package, so pin the TRANSFORMATIONS
  # rather than only their result on whichever files happen to exist. None of these three names a
  # real file — a guard that pins a filename goes red the day that file is legitimately renamed.
  test "an identifier is derived from its filename the way stimulus-loading derives it" do
    assert_equal "hello", self.class.identifier_for("hello_controller.js")
    assert_equal "file-menu", self.class.identifier_for("file_menu_controller.js")
    assert_equal "nested--file-menu", self.class.identifier_for("nested/file_menu_controller.js")
  end

  # THAT THE GLOB FEEDS THE RULE WHAT IT EXPECTS — relative paths, not absolute ones. `Dir.glob`'s
  # `base:` is the whole reason these come out relative; without it every identifier would be some
  # `--Users--charlesschwartz--…` shape matching nothing any view declares, and the sweep above would
  # report EVERY declaration as missing. That fails loudly rather than silently, but it would fail
  # for a reason nowhere near the truth, and this says so in one line instead.
  test "the glob yields well-formed identifiers" do
    refute_empty registered_identifiers
    registered_identifiers.each do |id|
      assert_match(/\A[a-z0-9]+(?:-{1,2}[a-z0-9]+)*\z/, id,
                   "#{id.inspect} is not a Stimulus identifier — check Dir.glob's `base:`")
    end
  end
end
