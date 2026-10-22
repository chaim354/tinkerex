require "test_helper"
require "tmpdir"

module Web
  # /settings/library and the redirect that sends a fresh share install there (K, 2026-10-20).
  #
  # EVERY TEST RUNS ON ALL THREE BACKEND LEGS AND BRANCHES, NEVER SKIPS (§15: the legs' RUN counts must
  # match). On share the behaviour is asserted present; on s3 and chunk_remote it is asserted absent --
  # nothing redirects, nothing is listed, nothing is written -- which is also the claim that the gate is
  # share-only. `@share` is the LEG, read off the ambient adapter before anything here moves it.
  #
  # On share the mount is a tmpdir of this test's own (LIBRARY_PATH, restored in teardown), so the
  # listing and the choice run against a real filesystem, and the scans they enqueue name its paths.
  #
  # The signed-in account is an ADMIN, as the first account always is: only an admin chooses the
  # folder (2026-10-21). What a plain account meets is its own section below.
  class SettingsLibraryTest < ActionDispatch::IntegrationTest
    include ActiveJob::TestHelper

    PASSWORD = "password123".freeze
    KEY = Tinkerex::LibraryRoot::KEY

    setup do
      @share = FileLayer.current.is_a?(FileLayer::Share)
      @mount = Pathname.new(Dir.mktmpdir("library-mount")).expand_path
      @prior_path = ENV["LIBRARY_PATH"]
      if @share
        ENV["LIBRARY_PATH"] = @mount.to_s
        FileLayer.reset!
      end
      @user = User.create!(email: "lib-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current, admin: true)
      sign_in_web!(@user, password: PASSWORD)
    end

    # Signs the admin out and a plain account of the same server in.
    def sign_in_plain_account!
      delete destroy_user_session_path
      @user = User.create!(email: "lib-plain-#{SecureRandom.hex(4)}@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      sign_in_web!(@user, password: PASSWORD)
    end

    teardown do
      @prior_path.nil? ? ENV.delete("LIBRARY_PATH") : ENV["LIBRARY_PATH"] = @prior_path
      FileLayer.reset!
      FileUtils.chmod_R(0o755, @mount) if @mount&.exist?
      FileUtils.remove_entry(@mount) if @mount&.exist?
    end

    def mkdirs(*rels) = rels.each { |rel| FileUtils.mkdir_p(@mount.join(rel)) }

    def json = JSON.parse(response.body)

    def live_node! = @user.nodes.create!(node_id: SecureRandom.uuid, name: "part.stl", kind: "file")

    # ============================================================ the redirect

    test "while the folder is unconfirmed every signed-in page goes to the library page, on share only" do
      Setting.forget(KEY)

      [ root_path, files_path, projects_path, tools_path, settings_path ].each do |path|
        get path
        if @share
          assert_redirected_to settings_library_path, "#{path} must wait for the library folder"
        else
          assert_response :success, "#{path} has no folder to wait for off share"
        end
      end
    end

    # Mutation-checked: drop the skip_before_action in Settings::LibraryController and the page
    # redirects to itself.
    test "the library page, Help, a JSON poller and sign-out are never redirected" do
      Setting.forget(KEY)

      get settings_library_path
      assert_response :success
      get help_path
      assert_response :success
      get scan_status_files_path, headers: { "Accept" => "application/json" }
      assert_response :success
      delete destroy_user_session_path
      assert_response :redirect
      assert_not_equal settings_library_path, URI(response.location).path
    end

    # Found in review: the redirect was HTML-only, so a JSON POST /files/rescan reached
    # ScanJob.enqueue_for -- a command, ungated by design -- and indexed the whole unconfirmed mount.
    # Mutation-checked: drop the 409 arm and the scan is enqueued.
    test "while the folder is unconfirmed a non-HTML write is refused, and scans nothing" do
      Setting.forget(KEY)

      post rescan_files_path, headers: { "Accept" => "application/json" }

      if @share
        assert_response :conflict
        assert_match(/Choose the library folder first/, json["error"])
        assert_no_enqueued_jobs
      else
        assert_not_equal 409, response.status
      end
    end

    # tinkerex:owner in another container, or any other process, writes the row behind this one's
    # back; the setting is cached per request, never per process, so the next request follows it.
    test "a choice written by another process is seen by the next request" do
      Setting.forget(KEY)
      get root_path
      assert_response(@share ? :redirect : :success)

      Setting.insert({ key: KEY, value: "", created_at: Time.current, updated_at: Time.current })

      get root_path
      assert_response :success
    end

    test "once the folder is chosen nothing redirects" do
      assert_equal "", Setting.get(KEY), "the fixture's confirmed library"

      get root_path
      assert_response :success
    end

    test "a fresh install's first sign-up lands on the library page on share, on Recent elsewhere" do
      delete destroy_user_session_path
      User.delete_all
      Setting.forget(KEY)

      post user_registration_path,
           params: { user: { email: "owner@example.com", password: PASSWORD, password_confirmation: PASSWORD } }
      follow_redirect!

      if @share
        assert_redirected_to settings_library_path
        follow_redirect!
        assert_select "h1", "Library folder"
        assert_select "button.btn.primary", "Use this folder"
      else
        assert_response :success
        assert_equal root_path, path
      end
    end

    # ============================================================ the listing

    test "the listing answers subfolders only, as paths relative to the mount" do
      mkdirs("Alpha", "beta/inner", ".config", "__MACOSX")
      @mount.join("notes.txt").write("x")
      outside = Dir.mktmpdir("outside")
      File.symlink(outside, @mount.join("linked").to_s)

      get children_settings_library_path, headers: { "Accept" => "application/json" }

      if @share
        assert_response :success
        assert_equal [ { "node_id" => "Alpha", "name" => "Alpha", "kind" => "dir" },
                       { "node_id" => "beta", "name" => "beta", "kind" => "dir" } ], json["entries"]
        assert_equal false, json["truncated"]

        get children_settings_library_path(parent: "beta"), headers: { "Accept" => "application/json" }
        assert_equal [ "beta/inner" ], json["entries"].map { |e| e["node_id"] }
        assert_equal [ { "node_id" => "beta", "name" => "beta" } ], json["crumbs"]
      else
        assert_response :not_found
      end
    ensure
      FileUtils.remove_entry(outside) if outside
    end

    test "the listing refuses a parent outside the mount with 422 and no entries" do
      outside = Dir.mktmpdir("outside")
      File.symlink(outside, @mount.join("escape").to_s)

      [ "..", "/etc", "escape", "a//b" ].each do |parent|
        get children_settings_library_path(parent:), headers: { "Accept" => "application/json" }
        if @share
          assert_response :unprocessable_entity, parent
          assert_nil json["entries"], "a refused parent lists nothing (#{parent})"
          assert json["error"].present?
        else
          assert_response :not_found
        end
      end
    ensure
      FileUtils.remove_entry(outside) if outside
    end

    # ============================================================ the choice

    test "confirming the whole folder on first run writes it and enqueues exactly one scan" do
      Setting.forget(KEY)

      if @share
        assert_enqueued_with(job: Library::ScanJob, args: [ { user_id: @user.id, root: @mount.to_s } ]) do
          patch settings_library_path, params: { relative: "" }
        end
        assert_equal 1, enqueued_jobs.size
        assert_equal "", Setting.get(KEY)
        assert_redirected_to root_path
      else
        assert_no_enqueued_jobs { patch settings_library_path, params: { relative: "" } }
        assert_nil Setting.get(KEY), "nothing to choose off share, so nothing is written"
      end
    end

    test "choosing a subfolder on first run scans that subfolder" do
      Setting.forget(KEY)
      mkdirs("Workshop/3d")

      patch settings_library_path, params: { relative: "Workshop/3d" }

      if @share
        assert_equal "Workshop/3d", Setting.get(KEY)
        assert_enqueued_with(job: Library::ScanJob, args: [ { user_id: @user.id, root: @mount.join("Workshop/3d").to_s } ])
      else
        assert_nil Setting.get(KEY)
        assert_no_enqueued_jobs
      end
    end

    test "a folder the app cannot write is refused with the user it runs as, and nothing is written" do
      skip "root writes through 0555" if Process.uid.zero?

      Setting.forget(KEY)
      mkdirs("locked")
      File.chmod(0o555, @mount.join("locked"))

      patch settings_library_path, params: { relative: "locked" }

      if @share
        assert_response :unprocessable_entity
        assert_includes response.body, "runs as user #{Process.uid}:#{Process.gid}"
        assert_nil Setting.get(KEY)
      end
      assert_no_enqueued_jobs
    end

    test "changing a folder with a catalog enqueues one change per user, keeping or starting over" do
      other = User.create!(email: "lib-o-#{SecureRandom.hex(4)}@example.com", confirmed_at: Time.current,
                           omniauth_signup: true)
      live_node!
      mkdirs("Alpha")

      patch settings_library_path, params: { relative: "Alpha" }
      if @share
        [ @user, other ].each do |u|
          assert_enqueued_with(job: Library::RootChangeJob, args: [ { user_id: u.id, start_over: false } ])
        end
        assert_redirected_to settings_library_path(scanning: 1)
      else
        assert_no_enqueued_jobs
      end

      clear_enqueued_jobs
      patch settings_library_path, params: { relative: "Alpha", start_over: "1" }
      if @share
        assert_enqueued_with(job: Library::RootChangeJob, args: [ { user_id: @user.id, start_over: true } ])
      else
        assert_no_enqueued_jobs
      end
    end

    test "start over on an empty catalog is a plain switch" do
      mkdirs("Alpha")

      patch settings_library_path, params: { relative: "Alpha", start_over: "1" }

      if @share
        assert_enqueued_with(job: Library::RootChangeJob, args: [ { user_id: @user.id, start_over: false } ])
      else
        assert_no_enqueued_jobs
      end
    end

    test "the shared demo account cannot change the folder" do
      prior = ENV["DEMO_ACCOUNT_EMAIL"]
      ENV["DEMO_ACCOUNT_EMAIL"] = @user.email
      mkdirs("Alpha")

      patch settings_library_path, params: { relative: "Alpha" }

      assert_redirected_to settings_library_path
      assert_equal "", Setting.get(KEY), "the demo's library folder is unchanged"
      assert_no_enqueued_jobs
      # Refused BY NAME, ahead of the admin gate that would refuse it anyway (its row says admin, and
      # User#can_manage_accounts? says no to the demo whatever the row says). Off share there is no
      # folder to choose, and that refusal comes first.
      if @share
        assert_equal "The shared demo account can't change the library folder.", flash[:alert]
      else
        assert_equal "This library has no folder to choose.", flash[:alert]
      end
    ensure
      prior.nil? ? ENV.delete("DEMO_ACCOUNT_EMAIL") : ENV["DEMO_ACCOUNT_EMAIL"] = prior
    end

    # ============================================================ a plain account (2026-10-21)

    # The gate is Settings::LibraryController#require_admin!. Mutation-checked: drop its before_action
    # and the folder changes and every account's catalog is queued for a rescan.
    test "a plain account cannot change the folder, and nothing is queued" do
      sign_in_plain_account!
      live_node!
      mkdirs("Alpha")

      [ { relative: "Alpha" }, { relative: "Alpha", start_over: "1" } ].each do |params|
        patch settings_library_path, params: params

        assert_redirected_to settings_library_path
        assert_equal(@share ? "Only an admin can change the library folder." : "This library has no folder to choose.",
                     flash[:alert])
        assert_equal "", Setting.get(KEY), "the folder is unchanged (#{params})"
        assert_no_enqueued_jobs
      end
    end

    # Pending is no exception: a plain account that meets an unconfirmed folder cannot confirm it.
    test "a plain account cannot confirm the folder on first run either" do
      Setting.forget(KEY)
      sign_in_plain_account!

      patch settings_library_path, params: { relative: "" }

      assert_redirected_to settings_library_path
      assert_nil Setting.get(KEY), "still unconfirmed"
      assert_no_enqueued_jobs
    end

    # The chooser lists the MOUNT, folders outside the library a plain account never sees.
    # Mutation-checked: take `children` out of require_admin!'s `only:` and the listing answers 200.
    test "a plain account cannot list the mount's folders" do
      sign_in_plain_account!
      mkdirs("Alpha")

      get children_settings_library_path, headers: { "Accept" => "application/json" }

      if @share
        assert_response :forbidden
        assert_equal "Only an admin can change the library folder.", json["error"]
        assert_nil json["entries"]
      else
        assert_response :not_found
      end
    end

    # Mutation-checked: render the form whatever @can_change says and the chooser is back on the page.
    test "a plain account sees the folder read-only, with the sentence that an admin changes it" do
      Setting.put(KEY, "Workshop")
      mkdirs("Workshop")
      sign_in_plain_account!
      live_node!
      @user.update_column(:library_scan_refusal, "UnsafeScan 9/10 (90.0% > 20%)")

      get settings_library_path

      assert_response :success
      assert_select "form[action=?]", settings_library_path, 0
      assert_select ".folder-field", 0
      assert_select "button[name=start_over]", 0
      if @share
        assert_select "strong code", "Workshop"
        assert_match(/1 file indexed/, response.body)
        assert_select "p.muted", /An admin changes the library folder, for every account on this server\./
        assert_select ".flash-alert", /refused: UnsafeScan 9\/10.*An\s+admin can choose the folder again here\./m
        assert_no_match(/Start over/, response.body, "the next step is the admin's")
      else
        assert_select "p.muted", /There is no folder to choose/
      end
    end

    test "a plain account at an unconfirmed folder is told it waits for an admin" do
      Setting.forget(KEY)
      sign_in_plain_account!

      get root_path
      assert_response(@share ? :redirect : :success)
      get settings_library_path

      assert_response :success
      assert_select "form[action=?]", settings_library_path, 0
      if @share
        assert_select "p", "This server's library folder has not been chosen yet."
        assert_select "p.muted", /An admin chooses the library folder for every account on this server\./
        assert_no_match(/Your library will be/, response.body)
        assert_no_match(/LIBRARY_HOST_PATH/, response.body)
      end
    end

    # ============================================================ the page

    test "the first-run page names the folder and offers the two ways to confirm it" do
      Setting.forget(KEY)

      get settings_library_path

      assert_response :success
      if @share
        assert_match(/Your library will be/, response.body)
        assert_select "form[action=?] input[name=relative][type=hidden][value='']", settings_library_path
        assert_select ".folder-field .ff-path", "Choose a folder inside it"
        assert_select ".folder-field[data-filechooser-children-url-value=?]", children_settings_library_path
        assert_select ".folder-field[data-filechooser-create-url-value]", 0, "no New Folder on the host's folders"
        assert_select "button[name=start_over]", 0
      else
        assert_select "form[action=?]", settings_library_path, 0
      end
    end

    test "the chosen page names the folder and its file count, and offers start over only with a catalog" do
      Setting.put(KEY, "Workshop")
      mkdirs("Workshop")

      get settings_library_path
      if @share
        assert_select "strong code", "Workshop"
        assert_match(/0 files indexed/, response.body)
        assert_select "button[name=start_over]", 0, "nothing to start over from"
      end

      live_node!
      get settings_library_path
      if @share
        assert_match(/1 file indexed/, response.body)
        assert_select "button.btn.primary:not([name])", "Switch to this folder"
        assert_select "button[name=start_over][value=\"1\"][data-turbo-confirm*=?]", "Nothing is deleted from disk"
      else
        assert_select "form[action=?]", settings_library_path, 0
      end
    end

    test "a refused scan is shown on the page with its next step" do
      @user.update_column(:library_scan_refusal, "UnsafeScan 9/10 (90.0% > 20%)")

      get settings_library_path

      if @share
        assert_select ".flash-alert", /The last scan of this folder was refused: UnsafeScan 9\/10/
      else
        assert_select ".flash-alert", 0
      end
    end

    test "the Settings hub links the library page and names the folder" do
      get settings_path

      assert_select "a.settings-name[href=?]", settings_library_path, text: "Library folder"
      assert_select ".settings-fact", text: @share ? "whole folder" : /storage bucket|sync server/
    end
  end
end
