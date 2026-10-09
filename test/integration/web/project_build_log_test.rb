require "test_helper"

module Web
  class ProjectBuildLogTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    # The project detail view reads file metadata + capabilities through FileLayer.current; pin a
    # real backend so the share CI leg (no LIBRARY_PATH) doesn't fail on backend construction.
    setup do
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "add a build-log entry" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_difference "project.build_log_entries.count", 1 do
        post project_build_log_entries_path(project), params: { build_log_entry: { body: "Cut the panels" } }
      end
      assert_redirected_to project_path(project)
      follow_redirect!
      assert_select ".log-entry .entry-body", text: /Cut the panels/
    end

    test "a blank entry body is rejected" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      assert_no_difference "Maker::BuildLogEntry.count" do
        post project_build_log_entries_path(project), params: { build_log_entry: { body: "" } }
      end
      assert_redirected_to project_path(project)
    end

    test "delete a build-log entry" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      entry = project.build_log_entries.create!(user:, body: "oops")
      assert_difference "project.build_log_entries.count", -1 do
        delete build_log_entry_path(entry)
      end
    end

    test "entries render newest first" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      project.build_log_entries.create!(user:, body: "first", logged_at: 2.days.ago)
      project.build_log_entries.create!(user:, body: "second", logged_at: 1.day.ago)
      get project_path(project)
      bodies = css_select(".log-entry .entry-body").map(&:text).map(&:strip)
      assert_equal [ "second", "first" ], bodies
    end

    # --- inline photos (attach existing) ---------------------------------------

    test "attach an existing image to a log entry renders it inline" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      entry = project.build_log_entries.create!(user:, body: "glued it")
      user.nodes.create!(node_id: "img-1", name: "clamp.png", kind: "file")

      assert_difference "entry.file_attachments.count", 1 do
        post entry_photos_path(entry), params: { node_id: "img-1" }
      end
      assert_equal "image", entry.file_attachments.last.role

      get project_path(project)
      assert_select ".log-entry .entry-photo[data-node-id=?]", "img-1"
    end

    # THE RACE TASK 9a's FOLLOW-UP CLOSES HERE, GENUINELY (Maker::AttachToProject#call's own
    # comment records the one place in this arc that turned out to already be safe — this is not
    # that case). Projects::EntryPhotosController#create called a BARE create!, with no find-first
    # step, so a concurrent request attaching the same photo raised ActiveRecord::RecordNotUnique
    # straight through to an uncaught 500 the moment the table gained its unique index. Drives the
    # REAL HTTP path (JSON, matching the chunk inline-upload flow this action also serves) under a
    # deterministically-injected race (with_concurrent_file_attachment, test_helper.rb).
    test "attaching a photo a concurrent request just attached answers 200, not a 500" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      entry = project.build_log_entries.create!(user:, body: "glued it")
      user.nodes.create!(node_id: "img-raced", name: "clamp.png", kind: "file")

      with_concurrent_file_attachment(role: "image") do
        post entry_photos_path(entry), params: { node_id: "img-raced" }, as: :json
      end

      assert_response :ok
      assert_equal 1, entry.file_attachments.where(node_id: "img-raced").count
    end

    test "attaching a photo refuses a node the user does not own" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      entry = project.build_log_entries.create!(user:, body: "x")
      other = User.create!(email: "z2@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "theirs", name: "p.png", kind: "file")
      assert_no_difference "Maker::FileAttachment.count" do
        post entry_photos_path(entry), params: { node_id: "theirs" }
      end
    end

    test "the entry form renders a Lexxy editor with attachments disabled" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      # ?add=build_log: an empty Build log is absent until "+ Add panel" opens it (slice 6).
      get project_path(project, add: "build_log")
      assert_response :success
      assert_select "lexxy-editor[attachments=?]", "false"
      assert_select "textarea[name=?]", "build_log_entry[body]", count: 0
    end

    test "a rich entry body round-trips its formatting" do
      user = sign_in
      project = user.maker_projects.create!(name: "Lamp")
      post project_build_log_entries_path(project),
           params: { build_log_entry: { body: "<p>Cut the <strong>panels</strong></p>" } }
      follow_redirect!
      assert_select ".entry-body strong", text: "panels"
    end
  end
end
