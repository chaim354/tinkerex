require "application_system_test_case"

# THE ONBOARDING WIZARD IN A BROWSER (2026-11-09; docs/superpowers/specs/2026-11-09-onboarding-wizard-design.md).
# A request test sees each step's markup; only a browser walks the whole thing: Recent's redirect, a
# real project with a real folder, and the top bar's Upload landing on Done with the file already
# filed. Share only (use_fresh_share_library!), as topbar_upload_test.rb is; the chunk uploader's
# redirect value is asserted in welcome_test.rb.
class OnboardingSystemTest < ApplicationSystemTestCase
  STL = "solid b\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 10 0 0\nvertex 0 10 0\nendloop\nendfacet\nendsolid b\n".freeze
  SVG = %(<svg xmlns="http://www.w3.org/2000/svg" width="20" height="10"><rect width="20" height="10"/></svg>\n).freeze

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("onboarding@example.com")
    @user.update_column(:onboarding_pending, true)
    @dir = Rails.root.join("tmp", "onboarding-#{SecureRandom.hex(4)}")
    @dir.mkpath
  end

  teardown do
    FileUtils.rm_rf(@dir)
    FileLayer.reset!
  end

  test "the 3D track ends on Done with the STL filed into models/" do
    stl = @dir.join("bracket.stl")
    File.write(stl, STL)

    visit root_path
    assert_current_path welcome_path
    click_on "Organize my 3D models"
    assert_selector ".welcome-card h2", text: "A 3D viewer that speaks millimetres"
    click_on "Next: your first project"
    fill_in "project[name]", with: "Wall Bracket"
    click_on "Create project"
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to Projects/wall-bracket"
    attach_file("topbar_upload_file", stl.to_s, make_visible: true)

    assert_selector ".page-head h1", text: "Wall Bracket is ready"
    assert_selector ".welcome-landed h3", text: "models/"
    assert_selector ".welcome-landed .grid-name", text: "bracket.stl"
    assert_not @user.reload.onboarding_pending?
    assert_no_console_errors
  end

  test "the files track ends on Done with the SVG filed into its type folder" do
    svg = @dir.join("panel.svg")
    File.write(svg, SVG)

    visit root_path
    click_on "Organize my files"
    click_on "Next: your first project"
    fill_in "project[name]", with: "Panel"
    select "Laser cutting", from: "project[kind]"
    click_on "Create project"
    # THE CAPTION IS THE WAIT, NOT DECORATION. Every page carries the top bar's file input, the Project
    # step's included (with no folder), so an attach that outruns the redirect uploads from THAT page
    # into the library root and lands on the file's own page (observed on the first run).
    assert_selector "header.topbar .topbar-upload-caption", text: "Saves to Projects/panel"
    attach_file("topbar_upload_file", svg.to_s, make_visible: true)

    assert_selector ".page-head h1", text: "Panel is ready"
    assert_selector ".welcome-landed h3", text: "#{Maker::ProjectFolders.folder_for(@user, 'panel.svg')}/"
    assert_selector ".welcome-landed .grid-name", text: "panel.svg"
    assert_equal "laser", @user.maker_projects.find_by!(name: "Panel").kind
    assert_no_console_errors
  end

  test "Skip for now leaves the wizard for good" do
    visit root_path
    click_on "Skip for now"
    assert_selector ".page-head h1", text: "Recent"
    visit root_path
    assert_current_path root_path
  end
end
