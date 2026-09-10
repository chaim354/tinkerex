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
  LAYER_ORDER = "@layer tokens, base, components, shell, pages;".freeze
  OURS = %w[
    application.css components.css shell.css
    pages/files.css pages/projects.css pages/models.css pages/tools.css pages/preview.css pages/home.css pages/inventory.css pages/settings.css pages/search.css pages/public.css
  ].freeze
  OVERRIDES = "vendor-overrides.css".freeze
  DELETED = %w[projects.css models.css notes.css].freeze
  COMPONENT_SELECTORS = %w[
    .btn .linkbtn .chip .view-toggle .toolbar .toolbar-count .breadcrumb .pager .page-head .panel .thumb
    .grid-card .badge dl.meta .empty .flash .file-menu .note-popover .filechooser
    table.files .folder-field-btn details.menu .tag-chips .tag-chip
    .panel-slot .panel-strip .layout-bar .layout-drawer
    .block-panel .block-link-card .page-intro .image-pick
    .panel-slot--tab .tabs .tab-bar .tab-pane .tab-link .tab-heading
  ].freeze

  def read(name) = SHEETS_DIR.join(name).read

  def strip_comments(css) = css.gsub(%r{/\*.*?\*/}m, "")

  # Every rule as [selector_text, enclosing_block_heads]. A block whose head starts with "@" is an
  # at-rule (layer, media, font-face, keyframes) and is not itself a rule; its children are.
  def rules(css)
    out = []
    stack = []
    buf = +""
    strip_comments(css).each_char do |ch|
      case ch
      when "{"
        head = buf.strip
        stack << head
        out << [ head, stack.dup ] unless head.start_with?("@")
        buf = +""
      when "}"
        stack.pop
        buf = +""
      when ";"
        buf = +""
      else
        buf << ch
      end
    end
    out
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

  test "the migrated sheets stay deleted" do
    DELETED.each { |name| refute SHEETS_DIR.join(name).exist?, "#{name} came back; its rules live under pages/ now" }
  end

  test "the layout links our sheets first, lexxy after, and the overrides last" do
    layout = LAYOUT.read
    order = %w[application components shell pages/files pages/projects pages/models pages/tools pages/preview pages/home pages/inventory pages/settings pages/search pages/public lexxy vendor-overrides]
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
end
