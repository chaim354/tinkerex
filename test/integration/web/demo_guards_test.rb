require "test_helper"
require "support/public_fixture"

module Web
  # THE SHARED DEMO ACCOUNT CANNOT LEAVE THE SANDBOX (Tinkerex::Demo; H, 2026-10-14). Every guard is
  # driven as the demo account signed in by its own button, and every one has a CONTROL beside it: the
  # identical request from an ordinary account on the same deployment, demo mode on, succeeding --
  # which is what proves each refusal keys on the account and leaves every other status unchanged.
  #
  # THE DEMO'S PASSWORD IS KNOWN HERE AND IS RANDOM IN PRODUCTION, deliberately: the account doors
  # are sent the RIGHT current password, so what refuses them is the guard and never Devise's own
  # "Current password is invalid". The demo also has its handle, as the reset gives it, so what
  # refuses publishing is the guard and never Maker::Project's "needs a handle first".
  #
  # Each refusal is a sentence on the page or in the body. Requests are the shapes the real forms
  # send, and the forms' rendered field names are asserted first (CLAUDE.md §14d): a test that posts
  # a Ruby hash proves nothing about a field the page names differently.
  class DemoGuardsTest < ActionDispatch::IntegrationTest
    include PublicFixture # make_owner!, sign_in_as, PASSWORD

    NEW_PASSWORD = "a different correct horse".freeze
    BEGIN_RESULT = Struct.new(:commit_id, :node_id, :put_urls, :missing)

    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    setup do
      @root = use_fresh_share_library!
      @prior = ENV.to_h.slice("DEMO_ACCOUNT_EMAIL", "DEMO_MAX_UPLOAD_BYTES")
      @demo = make_owner!(handle: "demo", email: "demo@example.com")
      @maker = make_owner!(handle: "maker")
      ENV["DEMO_ACCOUNT_EMAIL"] = @demo.email
      # A small cap, so the uploads below are a kilobyte and not twenty-five megabytes.
      ENV["DEMO_MAX_UPLOAD_BYTES"] = "1024"
    end

    teardown do
      %w[DEMO_ACCOUNT_EMAIL DEMO_MAX_UPLOAD_BYTES].each { |k| @prior.key?(k) ? ENV[k] = @prior[k] : ENV.delete(k) }
    end

    # WITH ITS PASSWORD, NOT ITS BUTTON. This suite keeps a CONTROL account on the same share library,
    # and that is exactly the state the button refuses (Tinkerex::Demo.available?: on share and s3
    # every account indexes the one library, so the door stays shut while another account exists --
    # demo_session_test.rb proves the refusal). The guards below key on the ACCOUNT, not on how it
    # signed in, which is what this suite is for.
    def sign_in_demo!
      sign_in_as(@demo)
      assert_redirected_to root_path, "the demo signs in with the password this suite knows"
    end

    def upload(name, bytes)
      Rack::Test::UploadedFile.new(StringIO.new("x" * bytes), "application/octet-stream", original_filename: name)
    end

    def account_update_params
      { user: { email: "new-address@example.com", password: NEW_PASSWORD,
                password_confirmation: NEW_PASSWORD, current_password: PASSWORD } }
    end

    # --- the account: email, password, existence ------------------------------------------------

    test "the demo account cannot change its email or password, even given the right current password" do
      sign_in_demo!
      get edit_user_registration_path
      %w[user[email] user[password] user[password_confirmation] user[current_password]].each do |field|
        assert_select "form[action=?] input[name=?]", user_registration_path, field
      end

      assert_no_emails { patch user_registration_path, params: account_update_params }
      assert_redirected_to edit_user_registration_path
      assert_match(/shared demo account/, flash[:alert].to_s)
      @demo.reload
      assert_equal "demo@example.com", @demo.email
      assert_nil @demo.unconfirmed_email, "reconfirmable parks a new address here; nothing may land at all"
      assert @demo.valid_password?(PASSWORD), "the password must not have changed"
    end

    test "control: an ordinary account's identical update changes its password" do
      sign_in_as(@maker)
      patch user_registration_path, params: account_update_params
      @maker.reload
      assert @maker.valid_password?(NEW_PASSWORD)
      assert_equal "new-address@example.com", @maker.unconfirmed_email
    end

    test "the demo account cannot delete itself, even given the right current password" do
      sign_in_demo!
      get edit_user_registration_path
      assert_select "div.account-delete form input[name=?]", "user[current_password]"

      assert_no_difference "User.count" do
        delete user_registration_path, params: { user: { current_password: PASSWORD } }
      end
      assert_redirected_to edit_user_registration_path
      assert_match(/shared demo account/, flash[:alert].to_s)
      assert User.exists?(@demo.id)
    end

    test "control: an ordinary account's identical delete removes it" do
      sign_in_as(@maker)
      assert_difference "User.count", -1 do
        delete user_registration_path, params: { user: { current_password: PASSWORD } }
      end
    end

    # NO MAIL, AND NOTHING ON THE WIRE THAT DIFFERS. Devise is paranoid here, so every address --
    # known, unknown -- gets the same redirect and notice; the demo's must too, or the reset form
    # becomes the one place that says which address is the demo, and it would mail a link nobody
    # should follow.
    test "a reset request for the demo address sends nothing and answers exactly as an unknown address does" do
      get new_user_password_path
      assert_select "form[action=?] input[name=?]", user_password_path, "user[email]"

      post user_password_path, params: { user: { email: "nobody@example.com" } }
      unknown = [ response.status, response.location, flash[:notice].to_s, response.body ]

      assert_no_emails do
        post user_password_path, params: { user: { email: " Demo@Example.com" } }
      end
      assert_equal unknown, [ response.status, response.location, flash[:notice].to_s, response.body ]
      assert_nil @demo.reload.reset_password_token, "no token was minted either"

      # Control: an ordinary address on the same deployment is mailed, and answered the same way.
      assert_emails 1 do
        post user_password_path, params: { user: { email: @maker.email } }
      end
      assert_equal unknown, [ response.status, response.location, flash[:notice].to_s, response.body ]
    end

    # --- publishing ----------------------------------------------------------------------------

    test "the demo cannot create a published project, and a private one is fine" do
      sign_in_demo!
      get new_project_path
      assert_select "form[action=?] input[name=?]", projects_path, "project[name]"

      # The new form has no visibility field; this is the hand-posted value the controller permits.
      assert_no_difference -> { Maker::Project.count } do
        post projects_path, params: { project: { name: "Desk Lamp", visibility: "public" } }
      end
      assert_response :unprocessable_entity
      assert_select ".form-errors", text: /shared demo can't publish/

      post projects_path, params: { project: { name: "Desk Lamp" } }
      assert_response :redirect
      assert_equal %w[private], @demo.maker_projects.pluck(:visibility)
    end

    test "control: an ordinary account's identical create publishes" do
      sign_in_as(@maker)
      post projects_path, params: { project: { name: "Desk Lamp", visibility: "public" } }
      assert_response :redirect
      assert_equal %w[public], @maker.maker_projects.pluck(:visibility)
    end

    test "the demo cannot publish from the Publish panel or the edit form, and saving it private still works" do
      sign_in_demo!
      project = @demo.maker_projects.create!(name: "Desk Lamp")
      get project_path(project)
      assert_select "form.publish-form" do
        assert_select "input[type=radio][name=?][value=?]", "project[visibility]", "public"
        assert_select "input[type=radio][name=?][value=?]", "project[visibility]", "unlisted"
        assert_select "input[type=hidden][name=?][value=?]", "return_to", "project"
      end

      %w[unlisted public].each do |visibility|
        patch project_path(project), params: { project: { visibility: }, return_to: "project" }
        assert_redirected_to project_path(project)
        assert_match(/shared demo can't publish/, flash[:alert].to_s, visibility)
        assert_equal "private", project.reload.visibility
      end

      # The edit form's branch of the same refusal re-renders, with the sentence on the form.
      patch project_path(project), params: { project: { visibility: "public" } }
      assert_response :unprocessable_entity
      assert_select ".form-errors", text: /shared demo can't publish/
      assert_equal "private", project.reload.visibility

      patch project_path(project), params: { project: { visibility: "private", name: "Desk Lamp II" }, return_to: "project" }
      assert_redirected_to project_path(project)
      assert_equal "Desk Lamp II", project.reload.name
    end

    test "control: an ordinary account's identical Publish panel save publishes" do
      sign_in_as(@maker)
      project = @maker.maker_projects.create!(name: "Desk Lamp")
      patch project_path(project), params: { project: { visibility: "public" }, return_to: "project" }
      assert_redirected_to project_path(project)
      assert_match(/Published at/, flash[:notice].to_s)
      assert_equal "public", project.reload.visibility
    end

    # --- the per-file upload cap, on both doors -----------------------------------------------

    test "the demo's upload over the cap is refused naming the limit, nothing is written, and the cap itself lands" do
      sign_in_demo!
      get files_path
      assert_select "form[action=?] input[type=file][name=?]", files_path, "file[]"

      sentence = "big.stl is larger than 1 KB, the most the shared demo takes in one file."
      post files_path, params: { file: [ upload("big.stl", 1025) ] }
      assert_redirected_to files_path
      assert_equal sentence, flash[:alert]
      assert_not @demo.nodes.exists?(name: "big.stl")
      assert_not @root.join("big.stl").exist?

      # A selection holding one file over the cap writes nothing, and names that file.
      post files_path, params: { file: [ upload("small.stl", 10), upload("big.stl", 1025) ] }
      assert_equal sentence, flash[:alert]
      assert_not @root.join("small.stl").exist?

      # The JSON callers (Save to library, the importer) read `error` off the body.
      post files_path, params: { file: upload("big.stl", 1025) }, headers: { "Accept" => "application/json" }
      assert_response :content_too_large
      assert_equal({ "error" => sentence }, JSON.parse(response.body))

      post files_path, params: { file: [ upload("edge.stl", 1024) ] }
      assert_match(%r{/files/[^/]+\z}, response.location, "a file at the cap lands: #{flash[:alert]}")
      assert @root.join("edge.stl").exist?
    end

    test "control: an ordinary account's identical upload lands" do
      sign_in_as(@maker)
      post files_path, params: { file: [ upload("big.stl", 1025) ] }
      assert_match(%r{/files/[^/]+\z}, response.location, flash[:alert].to_s)
      assert @root.join("big.stl").exist?
    end

    # THE THIRD UPLOAD DOOR: Projects::UploadsController, which the project page renders for each
    # build-log entry (the entry-photo uploader) and which the project-level route still reaches by
    # URL. Live on s3 -- what the public box runs -- and so capped like the other two.
    test "the demo's build-log upload over the cap is refused naming the limit, and nothing is written" do
      sign_in_demo!
      project = @demo.maker_projects.create!(name: "Desk Lamp")
      entry = project.build_log_entries.create!(user: @demo, body: "step one", logged_at: Time.current)
      get project_path(project)
      assert_select "form.uploader[action=?] input[type=file][name=?]", build_log_entry_uploads_path(entry), "file[]"

      sentence = "big.stl is larger than 1 KB, the most the shared demo takes in one file."
      post build_log_entry_uploads_path(entry), params: { file: [ upload("big.stl", 1025) ] }
      assert_response :redirect
      assert_equal sentence, flash[:alert]
      assert_not @demo.nodes.exists?(name: "big.stl")
      assert_empty entry.file_attachments

      # The project-level route is the same controller, reachable by URL.
      post project_uploads_path(project), params: { file: [ upload("big.stl", 1025) ] }
      assert_equal sentence, flash[:alert]
      assert_empty project.file_attachments
    end

    test "control: an ordinary account's identical build-log upload lands" do
      sign_in_as(@maker)
      project = @maker.maker_projects.create!(name: "Desk Lamp")
      entry = project.build_log_entries.create!(user: @maker, body: "step one", logged_at: Time.current)
      post build_log_entry_uploads_path(entry), params: { file: [ upload("big.stl", 1025) ] }
      assert_redirected_to project_path(project)
      assert_equal 1, entry.file_attachments.count, flash[:alert].to_s
    end

    # --- the handle ----------------------------------------------------------------------------

    test "the demo account cannot change its handle; the reset restores it anyway, but a visitor must not rename the demo for everyone" do
      sign_in_demo!
      get edit_user_registration_path
      assert_select "form[action=?] input[name=?]", settings_handle_path, "user[handle]"

      patch settings_handle_path, params: { user: { handle: "stolen" } }
      assert_redirected_to edit_user_registration_path
      assert_match(/shared demo account keeps its handle/, flash[:alert].to_s)
      assert_equal "demo", @demo.reload.handle
    end

    test "control: an ordinary account's identical handle change lands" do
      sign_in_as(@maker)
      patch settings_handle_path, params: { user: { handle: "renamed" } }
      assert_redirected_to edit_user_registration_path
      assert_equal "renamed", @maker.reload.handle
    end

    # THE PRESIGNED DOOR IS `syncable`-GATED, so the deployment is made syncable for these two --
    # constructing a ChunkRemote dials nothing -- and the port's begin_upload is stood in for, so the
    # control proves the request REACHED it rather than that a sync server answered.
    test "the demo's presigned upload over the cap is refused at begin with 413, before the port is asked" do
      FileLayer.current = FileLayer::ChunkRemote.new
      sign_in_demo!
      began = []
      replacing(FileLayer.current, :begin_upload, ->(*_, **kw) { began << kw; BEGIN_RESULT.new("c", "n", {}, []) }) do
        post begin_upload_files_path, params: { name: "big.stl", size: 1025,
                                                manifest: [ { hash: "h", offset: 0, length: 1025 } ] }, as: :json
      end
      assert_response :content_too_large
      assert_equal({ "error" => "big.stl is larger than 1 KB, the most the shared demo takes in one file." },
                   JSON.parse(response.body))
      assert_empty began
    end

    test "control: an ordinary account's identical begin reaches the port" do
      FileLayer.current = FileLayer::ChunkRemote.new
      sign_in_as(@maker)
      began = []
      replacing(FileLayer.current, :begin_upload, ->(*_, **kw) { began << kw; BEGIN_RESULT.new("c", "n", {}, []) }) do
        post begin_upload_files_path, params: { name: "big.stl", size: 1025,
                                                manifest: [ { hash: "h", offset: 0, length: 1025 } ] }, as: :json
      end
      assert_response :success
      assert_equal [ 1025 ], began.map { |kw| kw[:size] }
    end
  end
end
