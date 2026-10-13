require "test_helper"
require "support/fake_addon_source"
require "support/public_fixture"

module Web
  # A HELP PAGE, THE RAIL'S DOOR ONTO IT, AND A TOOLS PAGE THAT SPEAKS TO THE MAKER (onboarding,
  # 2026-10-13). A maker who is not the author had nowhere to read what the library is, what a
  # `Projects/` folder turns into or why a tool is missing, and /tools told them to set environment
  # variables. The variable names still exist on both pages, behind a collapsed "For the person
  # running this server" line; what these tests pin is that they left the maker's own sentences.
  #
  # Every assertion about the page's words is scoped to `main`: the rail and the top bar say
  # Library, Tools and Trash on every page, so a body-wide match would pass over a Help page that
  # said none of them.
  class HelpPageTest < ActionDispatch::IntegrationTest
    include PublicFixture

    OPERATOR = "For the person running this server".freeze

    setup do
      @root = use_fresh_share_library!
    end

    teardown { Maker::Addons::Source.reset! }

    # The house stub helper (new_menu_test.rb carries the same body; Minitest 6 has no Object#stub).
    # Replaces a SINGLETON method for the block, removing an inherited one after.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    def with_env(pairs)
      prior = pairs.keys.index_with { |key| ENV[key] }
      pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      yield
    ensure
      prior.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    end

    def main_text = css_select("main").text

    # The page with every collapsed operator section taken out: what a maker reads without opening
    # anything. A COPY, because the parsed document is memoised per response and a later
    # `assert_select` on the same page must still find the <details> this removes.
    def maker_text
      main = css_select("main").first
      assert main, "the page rendered no main element"
      main = main.dup
      main.css("details").each(&:remove)
      main.text
    end

    test "signed out, help redirects to sign-in like every other page" do
      get "/help"
      assert_redirected_to new_user_session_path
    end

    test "signed in, the help page explains the library, projects, tools and accounts" do
      sign_in_as(make_owner!(handle: "ada"))
      get "/help"
      assert_response :success
      assert_select "main .page-head h1", text: "Help"
      %w[library Projects/ Filing Rescan Trash Tools owner sign-ups].each do |word|
        assert_match(/#{Regexp.escape(word)}/i, main_text, "help page should mention #{word}")
      end
      [ settings_filing_rules_path, tools_path, trash_index_path, settings_shelves_path,
        files_models_path, edit_user_registration_path ].each do |path|
        assert_select "main a[href=?]", path
      end
    end

    # THE THREE WAYS A LIBRARY CAN BE BACKED, ASKED OF THE CAPABILITIES THE PAGE READS — never a
    # backend name, so the sentences stay right on every leg. `use_fresh_share_library!` pins share
    # on all three legs, so without swapping the capabilities the bucket and sync-server arms would
    # never render in any test and a typo in either would ship (CLAUDE.md §14d: a capability gate
    # that fails open is a bug you find in production).
    test "the library section says where files come from on each kind of backend" do
      sign_in_as(make_owner!(handle: "ada"))
      folder = FileLayer.current.capabilities
      assert folder.scannable?, "the fixture should be a share library"
      bucket = folder.with(presignable: true, local_worktree: false)
      sync = folder.with(scannable: false, syncable: true, versioned: true, port_writable: false,
                         local_worktree: false)

      replacing(FileLayer.current, :capabilities, -> { folder }) { get help_path }
      assert_match(/folder on this server/i, maker_text)
      assert_match(/Rescan library/, maker_text)
      assert_match(/keeps no older versions/i, maker_text)
      assert_no_match(/desktop app/i, maker_text)

      replacing(FileLayer.current, :capabilities, -> { bucket }) { get help_path }
      assert_match(/storage bucket/i, maker_text)
      assert_match(/Rescan library/, maker_text)
      assert_no_match(/folder on this server/i, maker_text)

      replacing(FileLayer.current, :capabilities, -> { sync }) { get help_path }
      assert_match(/desktop app/i, maker_text)
      assert_match(/keeps the version before it/i, maker_text)
      assert_no_match(/Rescan/, maker_text)
    end

    test "the operator's section is collapsed, and the maker's sections name no setting" do
      sign_in_as(make_owner!(handle: "ada"))
      get help_path
      assert_select "main details summary", text: OPERATOR
      assert_select "main details" do
        %w[ADDON_SOURCE_URL ADDON_SOURCE_PATH BOXES_SIDECAR_URL REGISTRATION SMTP_ADDRESS].each do |name|
          assert_select "code", text: /#{name}/
        end
        assert_select "a[href=?]", "https://github.com/chaim354/tinkerex"
        assert_select "a[href*='docs/INSTALL.md']"
      end
      assert_no_match(/ADDON_SOURCE|_SIDECAR_URL|REGISTRATION|SMTP_|tinkerex:password/, maker_text,
                      "a setting or a console command belongs behind the operator's <details>")
    end

    test "the rail offers Help beside Settings, named for the icon-only rail" do
      sign_in_as(make_owner!(handle: "ada"))
      get root_path
      assert_select "a.rail-btn[href='/help'][aria-label='Help']", 1
      # Collapsed (and below 1100px) the rail hides every `.rail-btn span`, so the button names
      # itself on the element and draws an icon, exactly as Settings and Sign out do.
      assert_select "aside.rail .rail-foot a.rail-help[title='Help'] svg.rail-icon", 1
      assert_select "aside.rail .rail-foot a.rail-help span", text: "Help"
      assert_select "aside.rail .rail-foot a.rail-help + a.rail-settings", 1
      assert_select "aside.rail .rail-foot a.rail-help[aria-current]", 0
    end

    # The foot's Settings link lights on its own pages (shell_layout_test.rb); Help does the same, so
    # the rail never shows nothing lit on a page it links to — and Settings goes dark here.
    test "the Help page lights the Help button and nothing else in the rail" do
      sign_in_as(make_owner!(handle: "ada"))
      get help_path
      assert_select "aside.rail .rail-foot a.rail-help[aria-current='page']", 1
      assert_select "aside.rail [aria-current='page']", 1
    end

    test "the Tools page speaks to the maker, not the operator" do
      sign_in_as(make_owner!(handle: "ada"))
      # The not-configured arm, pinned rather than assumed: a developer's own ADDON_SOURCE_PATH
      # would otherwise take this page down the other arm and the assertions with it.
      with_env("ADDON_SOURCE_URL" => nil, "ADDON_SOURCE_PATH" => nil) { get tools_path }
      assert_response :success
      body_without_details = response.body.gsub(%r{<details.*?</details>}m, "")
      leak = body_without_details[/.{0,60}(?:ADDON_SOURCE_URL|ADDON_SOURCE_PATH|_SIDECAR_URL).{0,60}/m]
      assert_nil leak, "environment-variable names belong behind the operator's <details>, " \
                       "not in the maker's copy: #{leak.inspect}"
      assert_match(/No tools are installed on this server/, maker_text)
      assert_select "main .empty a[href=?]", help_path(anchor: "tools")
      # MOVED, NOT DELETED: the person running the server still finds both settings, one click away.
      assert_select "main .empty details summary", text: OPERATOR
      assert_select "main .empty details code", text: "ADDON_SOURCE_URL"
      assert_select "main .empty details code", text: "ADDON_SOURCE_PATH"
    end

    test "a tool greyed out for a missing service names the service, not the variable" do
      sign_in_as(make_owner!(handle: "ada"))
      Maker::Addons::Source.stub = FakeAddonSource.new(manifests: [ {
        "key" => "boxes", "title" => "Box Generator", "icon" => "B", "description" => "Boxes",
        "api_version" => "1", "entry" => "boxes.js", "services" => [ "boxes" ]
      } ])
      with_env("BOXES_SIDECAR_URL" => nil) { get tools_path }
      assert_response :success
      reason = "Needs the boxes service, which this server doesn't run"
      assert_select "main .addon-card.disabled[title=?] .addon-desc", reason, text: reason
      leak = response.body.gsub(%r{<details.*?</details>}m, "")[/.{0,60}_SIDECAR_URL.{0,60}/m]
      assert_nil leak, "a greyed card named its environment variable: #{leak.inspect}"
    end
  end
end
