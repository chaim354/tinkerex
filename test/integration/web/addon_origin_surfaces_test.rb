require "test_helper"
require_relative "../../support/fake_addon_source"

module Web
  # "EDIT IN <ADDON>" ON ALL FOUR SURFACES — the Files list, the Files grid, a project's attachment
  # tiles, and the file detail page. Three of them feed `filemenu_controller.js` a data attribute and
  # the fourth renders a visible button plus a meta row; all four resolve through
  # AddonOrigins#addon_origins_for.
  #
  # SIBLING OF file_menu_wiring_test.rb, WHICH MAKES THE SAME ARGUMENT FOR `data-download-url`: the
  # system test proves the MENU renders an entry from an attribute, this proves every surface
  # actually writes one. They are different failures — a menu that reads an attribute no view emits
  # renders nothing, and a view that emits an attribute no menu reads renders nothing either, and
  # neither shows up in the other's test.
  #
  # BACKEND-NEUTRAL. Everything here is route helpers and `nodes`/`maker_addon_*` rows; nothing
  # writes bytes, so it runs identically on all three LIBRARY_BACKEND legs.
  class AddonOriginSurfacesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # `key` and `states_key` agree, which is the ordinary case — Registry defaults one to the other.
    # The divergent case is a states_key/shares_states_with pair and is unit-tested on `link_for`.
    MANIFEST = {
      "key" => "boxes", "title" => "Box Generator", "icon" => "📦",
      "description" => "Parametric boxes", "api_version" => "1", "entry" => "boxes.js"
    }.freeze

    # COUNTS `manifests` CALLS, AND A RAISING DOUBLE WOULD NOT DO. `Registry.manifests` rescues
    # StandardError and answers [], so a stub that raised would be swallowed and the "no Registry
    # call" test below would pass over the regression it exists to catch. Same note, same reason, as
    # Maker::AddonOriginTest's own counting double.
    class CountingAddonSource < FakeAddonSource
      attr_reader :fetches

      def initialize(**kw)
        super
        @fetches = 0
      end

      def manifests = (@fetches += 1) && super
    end

    setup do
      @user = User.create!(email: "origins-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      # Same two node shapes file_menu_wiring_test.rb uses: one the preview registry can render
      # (the `.file-cell` branch in both views) and one it cannot (the plain-link branch). Only the
      # first was produced by an addon, so every assertion below has a negative case beside it.
      @from_addon = @user.nodes.create!(node_id: "n-box", name: "box.svg", kind: "file",
                                        mtime: 1, size: 5)
      @plain = @user.nodes.create!(node_id: "n-plain", name: "readme.rtf", kind: "file",
                                   mtime: 1, size: 5)
      # revision 4, not the default 1, so an assertion on the rendered "v4" cannot pass against a
      # hardcoded number.
      @state = @user.maker_addon_states.create!(addon_key: "boxes", name: "shelf box",
                                                data: {}, revision: 4)
      @state.files.create!(node_id: @from_addon.node_id, role: "output", position: 0)
      @source = CountingAddonSource.new(manifests: [ MANIFEST ])
      Maker::Addons::Source.stub = @source
    end

    teardown { Maker::Addons::Source.reset! }

    def expected_url = tools_addon_path("boxes", state: @state.id)

    def open_urls = css_select("[data-addon-open-url]").map { |el| el["data-addon-open-url"] }

    test "the files list offers the addon that made the file, and nothing else" do
      get files_path(view: "list")

      assert_equal [ expected_url ], open_urls
      cell = css_select("[data-addon-open-url]").sole
      assert_equal "Edit in Box Generator", cell["data-addon-open-label"]
      assert_includes cell["href"], file_path(@from_addon.node_id)
    end

    test "the files grid offers it too" do
      get files_path(view: "grid")

      assert_equal [ expected_url ], open_urls
      assert_equal "Edit in Box Generator",
                   css_select("[data-addon-open-url]").sole["data-addon-open-label"]
    end

    # THE PLAIN-LINK BRANCH, WHICH IS A SEPARATE `data:` HASH IN BOTH VIEWS. `readme.rtf` has no
    # preview renderer, so it takes the branch that is easy to forget — the download-url wiring was
    # added to one branch and not the other first time round (see file_menu_wiring_test.rb).
    #
    # ASSERTS THE LABEL HERE TOO, NOT JUST THE URL, and that is the only place the pair is checked on
    # this branch: the two travel out of one hash built once in AddonOrigins, and a cell carrying the
    # url alone would put an entry reading "undefined" in the menu.
    test "the non-renderable branch of each view carries it as well" do
      @state.files.create!(node_id: @plain.node_id, role: "output", position: 1)

      %w[list grid].each do |view|
        get files_path(view:)
        cells = css_select("[data-addon-open-url]")
        assert_equal 2, cells.size, "the non-renderable cell in the #{view} view has no addon-open-url"
        assert_equal [ "Edit in Box Generator" ] * 2,
                     cells.map { |el| el["data-addon-open-label"] },
                     "a #{view} cell carries the url with no label — the menu would read 'undefined'"
      end
    end

    test "a project's attachment tiles offer it" do
      project = @user.maker_projects.create!(name: "Lamp")
      project.file_attachments.create!(user: @user, node_id: @from_addon.node_id, role: "model")
      project.file_attachments.create!(user: @user, node_id: @plain.node_id, role: "other")

      get project_path(project)

      assert_equal [ expected_url ], open_urls
      assert_equal "Edit in Box Generator",
                   css_select("[data-addon-open-url]").sole["data-addon-open-label"]
    end

    # THE FOURTH SURFACE IS NOT A MENU ATTRIBUTE — a visible button in the page actions, plus a meta
    # row naming the saved item and the revision the file came out of.
    test "the file page offers a button and names the saved item and its revision" do
      get file_path(@from_addon.node_id)

      assert_select "div.page-actions a[href=?]", expected_url, text: "Edit in Box Generator"
      assert_select "dl.meta dt", text: "Saved item"
      assert_select "dl.meta dd a[href=?]", expected_url, text: "shelf box"
      assert_select "dl.meta dd span.muted", text: "· v4"
    end

    test "a file no addon produced gets neither button nor meta row" do
      get file_path(@plain.node_id)

      assert_select "a[href=?]", expected_url, count: 0
      assert_select "dl.meta dt", text: "Saved item", count: 0
    end

    # THE MENU IS GATED ON `data-note-url` (`if (!noteUrl) return` in filemenu_controller.js), so a
    # cell carrying an addon-open-url and no note-url renders no menu at all and the entry is dead.
    # Same check file_menu_wiring_test.rb makes for the download url, for the same reason.
    test "every cell offering the addon link also carries the note url the menu is gated on" do
      get files_path
      cells = css_select("[data-addon-open-url]")
      assert_operator cells.size, :>=, 1
      assert cells.all? { |el| el["data-note-url"].present? },
             "a cell with an addon-open-url but no note-url renders no menu, so the entry is unreachable"
    end

    # NO REGISTERED ADDON CLAIMS THE KEY -> NO LINK AT ALL, rather than a /tools/<key> that 404s.
    # This is the live shape of an addon whose manifest has been withdrawn, and of an addon-source
    # outage (Registry.manifests answers [] for that request).
    test "output from an addon this deployment no longer serves gets no link" do
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ MANIFEST.merge("key" => "other") ])

      get files_path
      assert_empty open_urls
      get file_path(@from_addon.node_id)
      assert_select "dl.meta dt", text: "Saved item", count: 0
    end

    # THE PROPERTY THIS FEATURE MUST NOT LOSE. `Maker::Addons::Registry.all` fetches manifests over
    # HTTP behind a 5-minute cache; making the Files page depend on it unconditionally would turn an
    # addon-source outage into a slow library for a user who has never opened /tools. The cheap
    # indexed query runs FIRST and short-circuits — see AddonOrigins#addon_origins_for.
    #
    # ASSERTED IN BOTH DIRECTIONS. A bare `assert_equal 0` would pass just as well against a double
    # that was never wired up at all, so the same test proves the counter really does move on a page
    # that DOES have addon output.
    test "a page with no addon output never consults the addon registry" do
      @state.files.destroy_all

      get files_path
      assert_response :success
      get file_path(@plain.node_id)
      assert_response :success
      get project_path(@user.maker_projects.create!(name: "Empty"))
      assert_response :success
      assert_equal 0, @source.fetches,
                   "a library with no addon output fetched addon manifests #{@source.fetches} time(s)"

      # And the counter is really wired, so the zero above means "not called" rather than "not
      # counting". One page, one fetch — not one per file.
      @state.files.create!(node_id: @from_addon.node_id, role: "output", position: 0)
      get files_path
      assert_equal 1, @source.fetches
    end
  end
end
