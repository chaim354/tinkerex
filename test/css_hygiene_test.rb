require "test_helper"

# Guards the stylesheet architecture from the shell spec
# (docs/superpowers/specs/2026-09-03-web-shell-and-design-system-design.md §4.1, §7):
#
# - `application.css` OPENS with the @layer order statement, because the first @layer statement
#   the browser meets fixes the order for the document; a rule that lands in a layer before the
#   order is declared gets an order nobody chose.
# - EVERY rule of ours sits inside a layer. An unlayered rule outranks every layered one, so a
#   stray unlayered `.btn {}` in a page sheet would silently beat components.css — which is the
#   pre-2026-09 bug (two `.btn` definitions, the later file winning) with a new face.
# - `vendor-overrides.css` is the ONE unlayered sheet: it has to beat Lexxy's, CodeMirror's and the
#   spreadsheet's own unlayered CSS, and a layered rule cannot.
# - A COMPONENT SELECTOR IS DEFINED ONCE, in components.css. A page sheet may qualify a component
#   inside a container (`.files-grid .thumb`) — that is a different selector — but never redeclare
#   the bare one.
# - The three sheets the migration deleted stay deleted, and the layout links ours before the
#   vendor sheet and the overrides last.
#
# THE SCAN ASSERTS ITS OWN NON-VACUITY (§14e): a sheet that parses to zero rules fails rather than
# passing over nothing.
class CssHygieneTest < ActiveSupport::TestCase
  SHEETS_DIR = Rails.root.join("app/assets/stylesheets")
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")
  # The <head> the layout renders, and the one place the stylesheet links are written (2026-10-21:
  # shared with this app's turbo_rails/frame layout, see layouts/_head.html.erb).
  HEAD = Rails.root.join("app/views/layouts/_head.html.erb")
  LAYER_ORDER = "@layer tokens, base, components, shell, pages;".freeze
  OURS = %w[
    application.css components.css shell.css
    pages/files.css pages/projects.css pages/models.css pages/tools.css pages/preview.css pages/home.css pages/inventory.css pages/settings.css pages/search.css pages/public.css pages/landing.css pages/spreadsheet.css
  ].freeze
  OVERRIDES = "vendor-overrides.css".freeze
  DELETED = %w[projects.css models.css notes.css].freeze
  COMPONENT_SELECTORS = %w[
    .btn .linkbtn .chip .view-toggle .toolbar .toolbar-count .sort-form .breadcrumb .pager .page-head .panel .thumb
    .grid-card .badge dl.meta .empty .flash .file-menu .note-popover .filechooser
    table.files .folder-field-btn details.menu .tag-chips .tag-chip
    .panel-slot .panel-strip .layout-bar .layout-drawer
    .block-panel .block-link-card .page-intro .image-pick
    .panel-slot--tab .tabs .tab-bar .tab-pane .tab-link .tab-heading
    .render-card dialog.calculator .field-hint .btn-name
    .fig-num .plate .stack .note-box
    .panel-num .panel-note .page-columns .page-column
  ].freeze

  def read(name) = SHEETS_DIR.join(name).read

  def strip_comments(css) = css.gsub(%r{/\*.*?\*/}m, "")

  # Every rule as [selector_text, enclosing_block_heads, declarations]. A block whose head starts
  # with "@" is an at-rule (layer, media, container, font-face, keyframes) and is not itself a rule;
  # its children are. `declarations` is the rule's body, one "property: value;" after another.
  def rules(css)
    out = []
    stack = []
    buf = +""
    strip_comments(css).each_char do |ch|
      case ch
      when "{"
        head = buf.strip
        stack << head
        out << [ head, stack.dup, +"" ] unless head.start_with?("@")
        buf = +""
      when "}", ";"
        # Inside a rule (rules do not nest here), so the open rule is the last one recorded.
        in_rule = stack.last && !stack.last.start_with?("@")
        out.last[2] << " " << buf.strip << ";" if in_rule && !buf.strip.empty?
        stack.pop if ch == "}"
        buf = +""
      else
        buf << ch
      end
    end
    out.each { |rule| rule[2].strip! }
  end

  def layered?(enclosing) = enclosing.any? { |head| head.start_with?("@layer ") }

  def selectors_of(rule_head) = rule_head.split(",").map(&:strip)

  test "application.css opens with the layer order statement" do
    assert strip_comments(read("application.css")).lstrip.start_with?(LAYER_ORDER),
           "the first statement of application.css must be #{LAYER_ORDER}"
    OURS.each do |sheet|
      statements = strip_comments(read(sheet)).scan(/@layer\s+[\w, ]+;/)
      assert_equal (sheet == "application.css" ? [ LAYER_ORDER ] : []), statements,
                   "#{sheet}: the layer ORDER is declared once, in application.css"
    end
  end

  test "every rule in our sheets sits inside a cascade layer" do
    OURS.each do |sheet|
      parsed = rules(read(sheet))
      assert_operator parsed.size, :>, 5, "#{sheet} parsed to #{parsed.size} rules — the scan is vacuous"
      unlayered = parsed.reject { |_sel, enclosing| layered?(enclosing) }.map(&:first)
      assert_empty unlayered, "#{sheet}: rules outside any @layer: #{unlayered.inspect}"
    end
  end

  test "vendor-overrides.css is the one unlayered sheet" do
    parsed = rules(read(OVERRIDES))
    assert_operator parsed.size, :>, 3, "#{OVERRIDES} parsed to #{parsed.size} rules — the scan is vacuous"
    layered = parsed.select { |_sel, enclosing| layered?(enclosing) }.map(&:first)
    assert_empty layered, "#{OVERRIDES} must stay unlayered so it can outrank the vendor sheets: #{layered.inspect}"
  end

  test "a component selector is defined in components.css and nowhere else" do
    defined = rules(read("components.css")).flat_map { |sel, _| selectors_of(sel) }
    COMPONENT_SELECTORS.each do |component|
      assert_includes defined, component, "components.css does not define #{component}"
    end
    (OURS - [ "components.css" ] + [ OVERRIDES ]).each do |sheet|
      redeclared = rules(read(sheet)).flat_map { |sel, _| selectors_of(sel) } & COMPONENT_SELECTORS
      assert_empty redeclared, "#{sheet} redeclares component selector(s) #{redeclared.inspect}; only components.css may"
    end
  end

  # THE PRESSED LOOK IS DRAWN ONCE, IN components.css, FROM WHAT THE CONTROL ANNOUNCES
  # (`.btn[aria-pressed="true"]`). It was three declarations restated by each page that had a
  # toggle, in that page's own sheet, which is how the Gerber viewer came to have toggles with no
  # pressed look at all: nobody wrote its copy. A page sheet that styles a pressed selector is
  # starting the next copy. Qualified or bare makes no difference here, which is why rule 3's
  # check above (bare component selectors only) never saw these.
  test "only components.css draws a pressed control" do
    pressed = /\[aria-pressed/
    drawn = rules(read("components.css")).flat_map { |sel, _| selectors_of(sel) }.grep(pressed)
    assert_includes drawn, '.btn[aria-pressed="true"]', "components.css does not draw a pressed button"

    (OURS - [ "components.css" ]).each do |sheet|
      strays = rules(read(sheet)).flat_map { |sel, _| selectors_of(sel) }.grep(pressed)
      assert_empty strays, "#{sheet} styles a pressed control #{strays.inspect}; that look is components.css's alone"
    end
  end

  test "the migrated sheets stay deleted" do
    DELETED.each { |name| refute SHEETS_DIR.join(name).exist?, "#{name} came back; its rules live under pages/ now" }
  end

  test "the layout links our sheets first, lexxy after, and the overrides last" do
    assert_includes LAYOUT.read, %(render "layouts/head"), "the layout no longer renders the shared head"
    layout = HEAD.read
    order = %w[application components shell pages/files pages/projects pages/models pages/tools pages/preview pages/home pages/inventory pages/settings pages/search pages/public pages/landing pages/spreadsheet lexxy vendor-overrides]
    positions = order.map { |name| [ name, layout.index(%("#{name}")) ] }
    positions.each { |name, pos| assert pos, "the layout does not link #{name}" }
    assert_equal positions.map(&:last), positions.map(&:last).sort, "link order is #{positions.map(&:first).inspect}; it must be #{order.inspect}"
  end

  # --- A MAIN-CONTAINER VARIANT MUST ACTUALLY WIN (slice 0, 2026-09-10) --------------------
  #
  # `.auth-main` shipped as a BARE class in shell.css beside `main.container`, in the SAME layer.
  # Layer order cannot separate them, so specificity decides, and `main.container` (0,1,1) outranks
  # `.auth-main` (0,1,0): the auth card computed max-width 1360px where 440px was written, and
  # padding-top 20px where 48px was written — every sign-in and sign-up page rendered full width
  # from the day it shipped. `container-wide`, three lines away, is the same idea written correctly
  # (`main.container.container-wide`) and has always worked.
  #
  # TWO WAYS TO WIN, AND BOTH ARE LEGITIMATE — which is why this is not simply "qualify everything":
  # `.public-main` is a bare class too, but it lives in pages/public.css and `pages` comes AFTER
  # `shell` in the layer order, so it beats `main.container` on layer regardless of specificity.
  # Refusing that would be a false positive on correct CSS.
  #
  # THE VARIANT LIST IS DERIVED, NOT WRITTEN DOWN (the rule stimulus_hygiene_test follows): a new
  # `content_for :container_class, "x"` is covered with no edit here.
  CONTAINER_LAYER = "shell".freeze

  def container_variants
    from_views = Dir[Rails.root.join("app/views/**/*.erb")].flat_map do |f|
      File.read(f).scan(/content_for\s+:container_class,\s*"([\w-]+)"/).flatten
    end
    # The layout's own literal default for the signed-out branch.
    from_layout = File.read(LAYOUT).scan(/content_for\(:container_class\)[^"]*"([\w-]+)"/).flatten
    (from_views + from_layout).uniq
  end

  def layer_of(enclosing)
    head = enclosing.find { |h| h.start_with?("@layer ") && !h.include?(",") }
    head&.sub("@layer ", "")&.strip
  end

  test "every class the layout can put on main.container is written so it actually wins" do
    variants = container_variants
    assert_operator variants.size, :>=, 3,
                    "derived only #{variants.inspect} — the scan is vacuous"

    order = LAYER_ORDER.delete_prefix("@layer ").delete_suffix(";").split(",").map(&:strip)
    container_rank = order.index(CONTAINER_LAYER)
    offenders = []

    (OURS + [ OVERRIDES ]).each do |sheet|
      rules(read(sheet)).each do |head, enclosing|
        selectors_of(head).each do |sel|
          variants.each do |variant|
            # Only a selector whose SUBJECT is the variant competes with `main.container`;
            # `.public-main .pager` styles a descendant and is a different selector entirely.
            next unless sel == ".#{variant}" || sel == "main.container.#{variant}" ||
                        sel.match?(/\A(main)?(\.container)?\.#{Regexp.escape(variant)}\z/)
            next if sel.start_with?("main.container.")   # wins on specificity

            rank = order.index(layer_of(enclosing).to_s)
            next if rank && container_rank && rank > container_rank  # wins on layer order

            offenders << "#{sheet}: `#{sel}` is a bare class in layer " \
                         "#{layer_of(enclosing).inspect}, so `main.container` outranks it"
          end
        end
      end
    end

    assert_empty offenders,
                 "these container variants never apply:\n  #{offenders.join("\n  ")}"
  end

  # --- A COMPONENT OR SHELL RULE NAMES A TOKEN, NEVER A COLOUR (2026-10-08 redesign) -----------
  #
  # The thumbnail ink (#5f6873), the spinner (#d9dde3 / #7a8390) and the file-chooser scrim
  # (rgba(0, 0, 0, .55)) were literals in components.css. Each was right in exactly one theme and
  # a token flip could not reach it. Drawing colours (Measure, LightBurn, the tray top view) are
  # deliberately literal, and they live in pages/, which this guard does not scan. NOTHING IS
  # EXEMPT, A data: URI INCLUDED: the select chevron was the one literal allowed, because a colour
  # inside a data: URI cannot read a custom property, and so it was one grey in both themes. Since
  # 2026-11-19 the picture itself is a token (`--select-chevron`, redefined per theme in
  # application.css), so a new data: URI with a colour in it is refused like any other literal:
  # `%23`, a URI's spelling of `#`, counts as one (the exemption never needed to exist, because the
  # scan could not see the chevron's `%23878276` at all; mutation-checked, it can now).
  test "components.css and shell.css name tokens, not colours" do
    %w[components.css shell.css].each do |sheet|
      css = strip_comments(read(sheet))
      assert_operator css.length, :>, 1000, "#{sheet} is suspiciously short — the scan is vacuous"
      literals = css.scan(/(?:#|%23)\h{3,8}\b|rgba?\([^)]*\)|hsla?\([^)]*\)/)
      assert_empty literals, "#{sheet} carries colour literals #{literals.uniq.inspect}; add a token"
    end
  end

  # NO EMOJI IN THE INTERFACE, AND A STYLESHEET IS WHERE ONE HIDES (structural redesign, slice 5). The
  # model page's file tree drew 📁 and 🧊 through `::before { content: … }` for two slices after the
  # markup's emoji were swept, because no template grep can see a glyph that lives in CSS. Pictographs
  # only (U+1F300–U+1FAFF): the typographic marks status still uses (✓, ✕) are words, not emoji.
  test "no stylesheet draws an emoji through content" do
    sheets = Dir[SHEETS_DIR.join("**/*.css")]
    assert_operator sheets.size, :>, 5, "the sheet scan found almost nothing — it would pass over nothing"
    hits = sheets.flat_map do |path|
      strip_comments(File.read(path)).scan(/content:\s*"[^"]*"/).grep(/[\u{1F300}-\u{1FAFF}]/)
                                     .map { |decl| "#{Pathname.new(path).basename}: #{decl}" }
    end
    assert_empty hits, "a stylesheet draws an emoji; use a glyph helper (folder_glyph, rail_icon) in the markup"
  end

  # --- THE `hidden` ATTRIBUTE IS AUTHORITATIVE ONCE, IN `@layer base` (F-S34-2, 2026-10-19) ---------
  #
  # Any author `display` outranks the user agent's `[hidden] { display: none }`, so a component that
  # hid with the attribute needed its own `.x[hidden]` restatement: seven of them in three sheets,
  # each added after a shipped bug, while the page editor's YAML drawer, which had none, rendered
  # while hidden. ONE `!important` rule in the early base layer beats every later layer and the
  # unlayered vendor sheet (important declarations reverse the layer order). So a `[hidden]` selector
  # anywhere else is refused: it would be inert, and it would teach the next component to write its
  # own. `until-found` keeps the user agent's behaviour (find-in-page reveals it). The browser's half
  # is shell_test.rb's probe. Mutation-checked: deleting the base rule reddens this, and so does
  # putting `.addon-card[hidden]` back in pages/tools.css.
  HIDDEN_ATTRIBUTE = /\[\s*hidden\s*(?:[~|^$*]?=[^\]]*)?\]/
  HIDDEN_RULE = [ "application.css", "base", '[hidden]:not([hidden="until-found"])', "display: none !important;" ].freeze

  test "the hidden attribute is styled by one rule, in the base layer" do
    found = (OURS + [ OVERRIDES ]).flat_map do |sheet|
      rules(read(sheet)).flat_map do |head, enclosing, declarations|
        selectors_of(head).grep(HIDDEN_ATTRIBUTE).map { |sel| [ sheet, layer_of(enclosing), sel, declarations ] }
      end
    end
    assert_equal [ HIDDEN_RULE ], found,
                 "the `hidden` attribute has ONE rule, in application.css's base layer; anything else restates it"
  end

  # --- THE ADD-ON BUNDLES' CLASSES STAY STYLED (design-system.md rule 12, 2026-11-19) -------------
  #
  # The bundles in chaim354/tinkerex-addons ship no stylesheet: they build their markup from this
  # app's class names, so a class renamed or dropped here leaves a tool unstyled in another
  # repository with nothing red in this one. The contract was "52 classes" in one doc and "53" in
  # another, listed in a spec that was later deleted, and a scan of the bundles found 101. The list
  # is a file now, test/fixtures/addon_host_classes.txt (its header says how it was scanned), and
  # the first test fails when a class on it is no longer named by any selector under
  # app/assets/stylesheets. The second keeps the list honest against what this repo can see of the
  # bundles: every class the boxes snapshot under test/fixtures/addons puts on an element, and this
  # app styles, must be on it. Mutation-checked: renaming `.box-saved-name` in pages/tools.css
  # reddens the first, and deleting `box-field-wide` from the list reddens the second.
  ADDON_HOST_CLASSES = Rails.root.join("test/fixtures/addon_host_classes.txt")
  ADDON_SNAPSHOT = Rails.root.join("test/fixtures/addons")

  def addon_host_classes = ADDON_HOST_CLASSES.readlines(chomp: true).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }

  # Every class any selector in any sheet names: `.a`, `.b` and `.c` in `.a:not(.b) > .c`.
  def styled_classes
    Dir[SHEETS_DIR.join("**/*.css")].flat_map do |path|
      rules(File.read(path)).flat_map { |head, _| head.scan(/\.(-?[A-Za-z_][\w-]*)/).flatten }
    end.uniq
  end

  test "every class the add-on bundles build markup with is still styled" do
    listed = addon_host_classes
    assert_operator listed.size, :>=, 90, "#{ADDON_HOST_CLASSES} lists #{listed.size} classes; the scan found 101"
    assert_equal listed.uniq.sort, listed, "#{ADDON_HOST_CLASSES}: one class per line, sorted, none twice"
    styled = styled_classes
    assert_operator styled.size, :>, 300, "the sheets name only #{styled.size} classes; the parse is vacuous"
    orphaned = listed - styled
    assert_empty orphaned,
                 "no stylesheet styles #{orphaned.inspect} any more, and the add-on bundles build markup " \
                 "with them (design-system.md rule 12): restyle, never rename"
  end

  test "every styled class the boxes snapshot puts on an element is on the add-on list" do
    used = Dir[ADDON_SNAPSHOT.join("**/*.js")].flat_map do |path|
      src = File.read(path)
      src.scan(/\bclass="([^"]*)"/).flatten.flat_map { |c| c.gsub(/\$\{[^}]*\}/, " ").split } +
        src.scan(/\b(?:className\s*=|class:)\s*"([^"]*)"/).flatten.flat_map(&:split) +
        src.scan(/classList\.(?:add|remove|toggle)\("([^"]*)"/).flatten.flat_map(&:split) +
        src.scan(/\bclasses(?:\.push\(| = \[ )"([^"]*)"/).flatten
    end.uniq
    assert_operator used.size, :>, 50, "found #{used.size} class names in #{ADDON_SNAPSHOT}; the scan is vacuous"
    missing = (used & styled_classes) - addon_host_classes
    assert_empty missing,
                 "the boxes snapshot builds markup with #{missing.inspect}, which this app styles, and " \
                 "#{ADDON_HOST_CLASSES} does not list them: add them, sorted"
  end
end
