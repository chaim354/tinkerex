require "test_helper"

module Web
  # THE EDIT AREA, AFTER THE 2026-11-02 UX AUDIT (B1, B2, B3, C6, C10 and the §H copy), SERVER HALF.
  # What the browser does with these answers — the leave guard, the alert toasts, the confirms, the
  # draft surviving a refused Save — is test/system/page_editor_test.rb and its two siblings; this
  # file is the markup and the answers the server writes.
  #
  # MUTATION-CHECKED (§15), each run red and restored:
  #   - PanelsController#refuse answering the redirect for JSON too: the 422 test goes red.
  #   - ProjectsController#update redirecting a Publishing refusal again: the re-render test goes red.
  #   - ProjectsController#ensure_project_folder returning `e.class.name` into the notice again: the
  #     create test goes red on "FileLayer::".
  #   - "The link IS the credential" restored in projects/_publish: the copy test goes red.
  class ProjectEditAreaTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "edit-area-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = project_folder_rows!(@user, @project)
    end

    JSON_ACCEPT = { "Accept" => "application/json" }.freeze

    def draft(*panels) = { layout: 1, panels: }.to_json

    # --- B1: the editor's Save answers in place --------------------------------------------------

    test "the editor's Save, asked for JSON, sets the flash and names the page to visit" do
      patch project_panels_path(@project), params: { layout: draft({ key: "tasks", hidden: true, width: "full" }) },
                                           headers: JSON_ACCEPT

      assert_response :success
      assert_equal({ "location" => project_path(@project) }, response.parsed_body)
      assert_equal "Saved the page layout.", flash[:notice]
      assert_equal %w[tasks], @project.reload.panels["hidden"]
    end

    test "a refused Save, asked for JSON, is a 422 carrying the reason, never a redirect that reloads the editor" do
      @project.update!(panels: { "hidden" => %w[bom] })

      patch project_panels_path(@project), params: { layout: draft({ key: "tasks", hidden: true, width: "huge" }) },
                                           headers: JSON_ACCEPT

      assert_response :unprocessable_entity
      body = response.parsed_body
      assert_match(/\AThe layout was not saved: /, body["error"])
      refute_empty body["errors"]
      assert_nil flash[:alert], "the reason travels in the answer, not in a flash for a page nobody visits"
      assert_equal %w[bom], @project.reload.panels["hidden"], "a refused document writes nothing"

      patch project_panels_path(@project), params: { layout: "not json" }, headers: JSON_ACCEPT
      assert_response :unprocessable_entity
    end

    # A ROW'S OWN REFUSAL (a RecordInvalid inside the save's transaction) ENDS ITS SENTENCE: Rails'
    # `full_messages` carry no full stop, and the editor appends "Your changes are still on this
    # page." straight after the reason. Mutation-checked: dropping the full-stop line in
    # PanelsController#refuse turns the equality red.
    test "a refusal from the row itself is a whole sentence, ready for the editor to add to" do
      refusing = proc { |*| errors.add(:base, "Description is too long"); raise ActiveRecord::RecordInvalid, self }
      replacing(Maker::Project, :update!, refusing) do
        patch project_panels_path(@project), params: { layout: draft({ key: "tasks", hidden: true, width: "full" }) },
                                             headers: JSON_ACCEPT
      end

      assert_response :unprocessable_entity
      assert_equal "The layout was not saved: Description is too long.", response.parsed_body["error"]
    end

    # demo_guards_test.rb's helper, for an instance method: Minitest 6 has no Object#stub.
    def replacing(owner, name, replacement)
      own = owner.instance_methods(false).include?(name)
      original = owner.instance_method(name)
      owner.define_method(name, &replacement)
      yield
    ensure
      own ? owner.define_method(name, original) : owner.remove_method(name)
    end

    # --- B3: a Publishing refusal keeps what was typed -------------------------------------------

    test "a refusal on the Publishing tab re-renders the tab with the typed choice and the reason" do
      @user.update!(handle: "lamp-maker")
      prior = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV["DEMO_ACCOUNT_EMAIL"] = @user.email

      patch project_path(@project), params: { project: { visibility: "unlisted", license: "MIT" }, return_to: "publishing" }

      assert_response :unprocessable_entity
      assert_select "nav.edit-tabs a.tab-link.is-active[aria-current=page]", text: "Publishing"
      assert_select "section.publish-panel .form-errors.flash-alert[role=alert]", text: /shared demo can't publish/
      assert_select "input[type=radio][name=?][value=unlisted][checked=checked]", "project[visibility]"
      assert_select "select[name=?] option[value=MIT][selected=selected]", "project[license]"
      # THE LIVE PAGE IS STILL PRIVATE, so nothing on the tab offers a link to it: the typed
      # "Unlisted" is a choice that did not save, and a link to copy would be a link to nothing.
      assert_select ".publish-unlisted, .publish-url", 0
      assert_equal "private", @project.reload.visibility
    ensure
      prior ? ENV["DEMO_ACCOUNT_EMAIL"] = prior : ENV.delete("DEMO_ACCOUNT_EMAIL")
    end

    # --- B1: the Details and Publishing forms ask before typed input is left -----------------------

    # THE WIRING, AS RENDERED (§14d): a `data-controller` naming nothing is a silent no-op, and a
    # Boolean value the server never writes leaves a refused save's typed input unguarded. What the
    # browser does with it is test/system/project_edit_forms_test.rb.
    test "both forms carry the leave guard, and a refused save re-renders it already dirty" do
      @user.update!(handle: "lamp-maker")
      guard = "form[data-controller=dirty-form][data-action*='submit->dirty-form#disarm']" \
              "[data-action*='turbo:submit-start->dirty-form#disarm'][data-action*='turbo:submit-end->dirty-form#submitted']"

      get edit_project_path(@project)
      assert_select "#{guard}.project-form[data-dirty-form-dirty-value=false]", 1
      get publishing_project_path(@project)
      assert_select "#{guard}.publish-form[data-dirty-form-dirty-value=false]", 1

      patch project_path(@project), params: { project: { name: "" } }
      assert_response :unprocessable_entity
      assert_select "#{guard}.project-form[data-dirty-form-dirty-value=true]", 1
    end

    test "a refusal for want of a handle shows its reason above the claim form" do
      patch project_path(@project), params: { project: { visibility: "public" }, return_to: "publishing" }

      assert_response :unprocessable_entity
      assert_select "section.publish-panel > .form-errors.flash-alert[role=alert]", text: /needs a handle/
      assert_select "section.publish-panel form[action=?]", settings_handle_path
      assert_equal "private", @project.reload.visibility
    end

    # --- C10: a folder that could not be made, in a maker's words ---------------------------------

    test "a project whose folder could not be made is created, and the alert says why without a class name" do
      broken = Object.new
      def broken.capabilities = Object.new.tap { |c| def c.port_writable? = true }
      def broken.mkdir(*) = raise(FileLayer::FetchError, "down")
      FileLayer.current = broken

      post projects_path, params: { project: { name: "No Folder" } }

      assert_predicate @user.maker_projects.find_by(slug: "no-folder"), :present?
      assert_equal "Created No Folder.", flash[:notice]
      assert_match(/library could not be reached, so the project folder was not created yet/, flash[:alert])
      refute_match(/FileLayer|Error/, "#{flash[:notice]} #{flash[:alert]}")
    ensure
      FileLayer.reset!
    end

    # --- C6: the three tabs agree -----------------------------------------------------------------

    test "each tab's Save names what it saves, and each is followed by the same Cancel back to the project" do
      @user.update!(handle: "lamp-maker")
      { edit_project_path(@project) => "Save changes",
        publishing_project_path(@project) => "Save publishing",
        edit_layout_project_path(@project) => "Save layout" }.each do |path, label|
        get path
        assert_response :success
        assert_select "input[type=submit][value=?]", label, 1
        assert_select "a.linkbtn.edit-cancel[href=?]", project_path(@project), { text: "Cancel", count: 1 }, path
        assert_select ".edit-head a.edit-done[href=?][title=?]", project_path(@project), "Back to the project page"
      end
    end

    # --- C10 and §H: the editor's controls and its words ------------------------------------------

    test "the layout bar says no YAML, and Add tab at the cap says why in text on the page" do
      get edit_layout_project_path(@project)
      assert_select ".layout-bar button", text: "Edit as text"
      assert_select ".layout-drawer b", text: "Layout as text"
      refute_match(/YAML/, css_select(".layout-bar, .layout-drawer").map(&:text).join(" "))
      assert_select ".layout-tab-cap", 0

      eight = (1..8).map { |i| Maker::ProjectKind.tab_key(format("%012x", i)) }
      @project.update!(panels: { "order" => [ "attachments", *eight, "photos" ], "titles" => eight.to_h { |k| [ k, k.last(4) ] } })
      get edit_layout_project_path(@project)
      assert_select "button[data-action='layout-editor#addTab'][disabled]:not([title])", 1
      assert_select ".layout-bar .layout-tab-cap", text: "This page has #{Maker::ProjectKind::TAB_CAP} tabs, the most it can hold."
      # Up and Down on every separator, so a tab is never drag-only — the grid's eight, and the
      # template Add tab clones (the ninth, which a parser sees and a browser keeps inert).
      assert_select "div.project-panels.layout-editing > div.panel-slot--tab", 8
      assert_select "div.panel-slot--tab", 9 do |tabs|
        tabs.each do |tab|
          assert_select tab, "button[data-action='layout-editor#up'][aria-label=?]", "Move this tab up"
          assert_select tab, "button[data-action='layout-editor#down'][aria-label=?]", "Move this tab down"
        end
      end
    end

    test "Reset tells the editor once its confirm is answered, so its redirect does not ask a second time" do
      get edit_layout_project_path(@project)
      assert_select "form[action=?][data-turbo-confirm][data-action=?]", project_panels_path(@project),
                    "turbo:submit-start->layout-editor#discard turbo:submit-end->layout-editor#resumeGuard"
    end

    test "the Details form says cover, never hero, and the unlisted link explains itself in plain words" do
      get edit_project_path(@project)
      refute_match(/\bhero\b/i, css_select("form.project-form").text)
      assert_select ".field-hint", text: /which kind\s+of file it uses as the cover/

      @user.update!(handle: "lamp-maker")
      @project.update!(visibility: "unlisted")
      get publishing_project_path(@project)
      assert_select ".publish-unlisted p", text: "Anyone with this link can open the page. Making a new link stops the old one working."
      refute_match(/credential/i, css_select("section.publish-panel").text)
    end

    test "a new unlisted link is announced verb first, and says the old link stopped working" do
      @user.update!(handle: "lamp-maker")
      @project.update!(visibility: "unlisted")
      post project_unlisted_token_path(@project)
      assert_equal "Made a new unlisted link. The old one no longer works.", flash[:notice]
    end
  end
end
