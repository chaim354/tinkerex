require "application_system_test_case"
require "tmpdir"

# THE FIRST RUN OF A SHARE INSTALL, IN A REAL BROWSER (K, 2026-10-20): sign up, land on the library
# page, pick a subfolder of the mount in the chooser, confirm it, and find it named on Recent.
#
# WHY THIS TIER: the chooser is lib/file_chooser.js built at click time, fed by `fetch` from
# Settings::LibraryController#children, and writing its pick into a hidden input through the
# `filechooser` Stimulus controller -- none of which an integration test can drive (file_chooser_
# test.rb says the same of the node-based chooser). It is also the only tier that sees the modal
# offer no "New Folder" when the field passes no create URL, and the only one that sees the CSP.
#
# ONE TEST, BRANCHED, NEVER SKIPPED (§15's matching RUN counts): off share there is nothing to
# choose and the first sign-up lands on Recent directly, which is asserted.
class LibraryChooserTest < ApplicationSystemTestCase
  include WebHelpers

  setup do
    @share = FileLayer.current.is_a?(FileLayer::Share)
    @mount = Pathname.new(Dir.mktmpdir("chooser-mount")).expand_path
    FileUtils.mkdir_p(@mount.join("Workshop/3d"))
    FileUtils.mkdir_p(@mount.join("Downloads"))
    @prior_path = ENV["LIBRARY_PATH"]
    if @share
      ENV["LIBRARY_PATH"] = @mount.to_s
      FileLayer.reset!
    end
    # A FRESH INSTALL: no account, no stored choice.
    User.delete_all
    Setting.forget(Tinkerex::LibraryRoot::KEY)
  end

  teardown do
    @prior_path.nil? ? ENV.delete("LIBRARY_PATH") : ENV["LIBRARY_PATH"] = @prior_path
    FileLayer.reset!
    FileUtils.remove_entry(@mount) if @mount&.exist?
  end

  test "the first account confirms a subfolder of the mount before anything is indexed" do
    visit new_user_registration_path
    fill_in "user[email]", with: "owner@example.com"
    fill_in "user[password]", with: WebHelpers::PASSWORD
    fill_in "user[password_confirmation]", with: WebHelpers::PASSWORD
    click_on "Sign up"

    unless @share
      assert_current_path "/"
      assert_no_console_errors
      return
    end

    assert_current_path settings_library_path
    assert_text "Your library will be"

    click_on "Choose a folder inside it"
    assert_selector ".filechooser-overlay"
    assert_no_selector ".filechooser-new", visible: true # the host's folders are made on the host
    within(".filechooser-cols") do
      assert_text "Downloads"
      find(".filechooser-row", text: "Workshop").click
      find(".filechooser-row", text: "3d").click
    end
    assert_text "Selected: /Workshop/3d"
    click_on "Choose"
    assert_no_selector ".filechooser-overlay"

    # BOTH HALVES OF THE COMMIT: the label the person reads, and the input the form submits.
    assert_selector ".ff-path", exact_text: "/Workshop/3d"
    assert_equal "Workshop/3d", find("input[name='relative']", visible: false).value

    click_on "Use this folder"
    assert_current_path "/"
    within(".getting-started .file-sources") { assert_text "Workshop/3d" }
    assert_equal "Workshop/3d", Setting.get(Tinkerex::LibraryRoot::KEY)
    assert_no_console_errors
  end
end
