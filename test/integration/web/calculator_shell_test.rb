require "test_helper"
require "support/public_fixture"

module Web
  # THE CALCULATOR IN THE SHELL (2026-10-21; plan 2026-10-21-calculator-modal.md): the modal rendered
  # once on every signed-in page and on no other, the rail's pinned link, the Tools card and its pin
  # toggle. What a browser alone can see — opening, Enter, Esc, focus, saving — is
  # test/system/calculator_modal_test.rb's.
  class CalculatorShellTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @user = make_owner!(handle: "shell-#{SecureRandom.hex(3)}")
      sign_in_as(@user)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
    end

    test "every signed-in page renders the modal exactly once, closed, with nothing accent in it" do
      [ root_path, files_path, projects_path, project_path(@project), tools_path, settings_path, help_path ].each do |path|
        get path
        assert_response :success, path
        assert_select "body > .calculator-host[data-controller=calculator] > dialog.calculator", 1, path
        assert_select "dialog.calculator[open]", 0, "#{path}: the modal must render closed"
        assert_select "dialog.calculator .primary", 0, "#{path}: the accent is spent once per screen"
        assert_select "dialog.calculator input#calculator-input", 1
      end
    end

    test "the save frame is fetched later, and names this page's project only on a project page" do
      get project_path(@project)
      assert_select ".calculator-host[data-calculator-save-url-value=?]", new_calculation_path(project_id: @project.id)
      # No src: the frame asks for the project list only when the maker opens Save to project.
      assert_select "dialog.calculator turbo-frame#calculator-save:not([src])", 1

      get files_path
      assert_select ".calculator-host[data-calculator-save-url-value=?]", new_calculation_path
    end

    test "a visitor's page and the sign-in page have no calculator" do
      use_fresh_share_library!
      @project.update!(visibility: "public")
      get public_project_path(@user.handle, @project.slug)
      assert_response :success
      assert_select "dialog.calculator", 0

      delete destroy_user_session_path
      get new_user_session_path
      assert_select "dialog.calculator", 0
    end

    test "unpinned, the rail has no Calculator link and the Tools card offers the pin" do
      get tools_path
      assert_select "aside.rail a.rail-calculator", 0
      assert_select "#calculator.calculator-card button[data-calculator-open]", text: "Open calculator"
      assert_select "#calculator form.calculator-pin-form[action=?][method=post] button", tools_calculator_pin_path,
                    text: "Pin to sidebar"
      assert_select "#calculator form.calculator-pin-form input[name=_method]", 0
    end

    test "pinning puts a Calculator link in the rail on every page; it opens the modal and lights nothing" do
      post tools_calculator_pin_path
      assert_redirected_to tools_path
      assert @user.reload.calculator_pinned?

      [ root_path, project_path(@project), tools_path ].each do |path|
        get path
        assert_select "aside.rail .rail-nav--foot a.rail-calculator[data-calculator-open][href=?]",
                      tools_path(anchor: "calculator"), 1
        assert_select "aside.rail a.rail-calculator[aria-current]", 0
        # STILL EXACTLY ONE LIT LINK (design-system.md rule 8).
        assert_select "aside.rail [aria-current='page']", 1
        # The phone tab bar keeps its four destinations.
        assert_select "nav.tabbar a.tabbar-link", 4
      end
      # Under Tools, which is the tool family it belongs to.
      foot = css_select("aside.rail .rail-nav--foot li a").map { |a| a["title"] }
      assert_equal foot.index("Tools") + 1, foot.index("Calculator")

      get tools_path
      assert_select "#calculator form.calculator-pin-form input[name=_method][value=delete]", 1
      assert_select "#calculator form.calculator-pin-form button", text: "Unpin from sidebar"
    end

    test "unpinning takes the link away" do
      @user.update_column(:calculator_pinned, true)
      delete tools_calculator_pin_path
      assert_redirected_to tools_path
      refute @user.reload.calculator_pinned?
      get root_path
      assert_select "aside.rail a.rail-calculator", 0
    end

    test "the pin is per user: pinning for one account leaves another's rail alone" do
      post tools_calculator_pin_path
      other = make_owner!(handle: "other-#{SecureRandom.hex(3)}")
      delete destroy_user_session_path
      sign_in_as(other)
      get root_path
      assert_select "aside.rail a.rail-calculator", 0
    end

    test "a pin saves even when the account carries a handle a later rule now reserves" do
      # `calculations` joined RESERVED_HANDLES with this feature; a row minted before that must
      # still be able to pin, which is why the door writes one column and runs no validation.
      @user.update_column(:handle, "calculations")
      refute @user.reload.valid?
      post tools_calculator_pin_path
      assert_redirected_to tools_path
      assert @user.reload.calculator_pinned?
    end

    test "signed out, the pin door goes to sign-in" do
      delete destroy_user_session_path
      post tools_calculator_pin_path
      assert_redirected_to new_user_session_path
    end
  end
end
