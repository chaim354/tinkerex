require "test_helper"
require "tmpdir"

module Web
  # A REFUSED SCAN, SAID FOR A MAKER (UX audit F8). /settings/library printed the scan's own message --
  # "scan would tombstone 9/10 observable files (90.0% > 20%). Refusing — is the share mounted? Set
  # LIBRARY_SCAN_MAX_DELETE_PCT to override." -- to every account. The page now says it in its own
  # words, with the numbers, and only the admin's version names the variable.
  #
  # THE FIXTURE IS THE RECONCILER'S OWN RAISE, NOT A STRING WRITTEN HERE. Settings::LibraryController
  # reads the numbers out of that message (it is all the column holds), so a fixture typed into this
  # file would keep passing after the Reconciler's wording moved and the page had quietly fallen to its
  # generic sentence. Runs on every leg and branches, never skips (§15): only share shows the page's
  # folder and its alerts.
  class SettingsLibraryRefusalTest < ActionDispatch::IntegrationTest
    PASSWORD = "password123".freeze

    setup do
      @share = FileLayer.current.is_a?(FileLayer::Share)
      @mount = Pathname.new(Dir.mktmpdir("library-mount")).expand_path
      @prior_path = ENV["LIBRARY_PATH"]
      if @share
        ENV["LIBRARY_PATH"] = @mount.to_s
        FileLayer.reset!
      end
      @user = User.create!(email: "refusal-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current, admin: true)
    end

    teardown do
      @prior_path.nil? ? ENV.delete("LIBRARY_PATH") : ENV["LIBRARY_PATH"] = @prior_path
      FileLayer.reset!
      FileUtils.remove_entry(@mount) if @mount&.exist?
    end

    # The message Library::Reconciler#guard_mass_deletion! raises for `doomed` of `total` at a 20% limit.
    def real_refusal(doomed, total)
      reconciler = Library::Reconciler.new(@user, observations: [], unreadable_dirs: [], max_delete_pct: 20,
                                                  root: @mount)
      reconciler.send(:guard_mass_deletion!, doomed, total)
      flunk "the Reconciler did not refuse #{doomed}/#{total}"
    rescue Library::Scanner::UnsafeScan => e
      e.message
    end

    # MUTATION-CHECKED: printing @refusal in the alert again (the old `<%= @refusal %>`) reddens the
    # raw-message assertion; the run's output is in the UX-audit T6 report.
    test "an admin reads the refusal as a sentence with its numbers, its next step and the limit's name" do
      @user.update_column(:library_scan_refusal, real_refusal(9, 10))
      sign_in_web!(@user, password: PASSWORD)

      get settings_library_path

      assert_response :success
      if @share
        assert_select ".flash-alert", /would have removed 9 of\s+10 files from the catalog, more than the 20% one\s+scan\s+may remove/
        assert_select ".flash-alert", /Check that the folder is mounted and holds your files, then rescan\./
        assert_select ".flash-alert code", "LIBRARY_SCAN_MAX_DELETE_PCT"
        assert_select ".flash-alert strong", "Start over"
        assert_no_match(/tombstone|observable|Refusing/, response.body, "the scan's own message never prints")
      else
        assert_select ".flash-alert", 0
      end
    end

    test "a plain account reads the same sentence and is told an admin acts on it" do
      plain = User.create!(email: "refusal-plain-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      plain.update_column(:library_scan_refusal, real_refusal(30, 40))
      sign_in_web!(plain, password: PASSWORD)

      get settings_library_path

      assert_response :success
      if @share
        assert_select ".flash-alert", /would have removed 30 of\s+40 files/
        assert_select ".flash-alert", /An admin can raise the limit or\s+choose the folder again here\./
        assert_select ".flash-alert code", 0, "the variable is the admin's"
        assert_no_match(/tombstone|LIBRARY_SCAN_MAX_DELETE_PCT/, response.body)
      else
        assert_select ".flash-alert", 0
      end
    end
  end
end
