require "test_helper"

module Web
  # Inline photos on a build-log entry: attach an EXISTING image node to the entry, or remove the
  # reference. No byte writes — a Maker::FileAttachment pointing at a library node.
  #
  # #destroy had NO test at all, which for a mutating action that takes an :id is the shape most
  # likely to hide a missing ownership scope.
  class EntryPhotosTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "logger@example.com", password: PASSWORD,
                           confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @project = @user.maker_projects.create!(name: "Logged", status: "active")
      @entry = @project.build_log_entries.create!(user: @user, body: "step one",
                                                  logged_at: Time.current)
      @user.nodes.create!(node_id: "photo1", name: "photo1.png", kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)
    end

    def attach!(node_id = "photo1")
      post entry_photos_path(@entry), params: { node_id: }
    end

    test "attaching an existing image node to an entry" do
      assert_difference "Maker::FileAttachment.count", 1 do
        attach!
      end
      assert_redirected_to project_path(@project)
      assert_equal "image", @entry.file_attachments.last.role
    end

    test "attaching a node that is not in the library is refused" do
      assert_no_difference "Maker::FileAttachment.count" do
        attach!("nope")
      end
      assert_redirected_to project_path(@project)
    end

    test "attaching answers JSON for the inline uploader" do
      # uploader_controller.js needs the node_id back in the same request; a followed redirect
      # cannot carry it. This is the same 406-shaped trap FilesController#create hit.
      post entry_photos_path(@entry), params: { node_id: "photo1" }, as: :json
      assert_response :created
      assert_equal "photo1", response.parsed_body["node_id"]
    end

    test "removing a photo detaches it" do
      attach!
      att = @entry.file_attachments.last

      assert_difference "Maker::FileAttachment.count", -1 do
        delete entry_photo_path(att)
      end
      assert_redirected_to project_path(@project)
    end

    test "removing a photo leaves the library node alone" do
      attach!
      att = @entry.file_attachments.last

      delete entry_photo_path(att)

      assert @user.nodes.present.exists?(node_id: "photo1"),
             "detaching a photo must not delete the file from the library"
    end

    test "another user cannot attach their own file to this entry" do
      other_email = "intruder@example.com"
      other = User.create!(email: other_email, password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "theirs", name: "theirs.png", kind: "file", size: 1,
                          mtime: 1_700_000_000_000_000_000)

      delete destroy_user_session_path
      post user_session_path, params: { user: { email: other_email, password: PASSWORD } }

      assert_no_difference "Maker::FileAttachment.count" do
        post entry_photos_path(@entry), params: { node_id: "theirs" }
      end
      assert_not response.successful?
    end

    test "another user cannot remove this entry's photo" do
      attach!
      att = @entry.file_attachments.last

      delete destroy_user_session_path
      other_email = "intruder2@example.com"
      User.create!(email: other_email, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: other_email, password: PASSWORD } }

      assert_no_difference "Maker::FileAttachment.count" do
        delete entry_photo_path(att)
      end
      assert Maker::FileAttachment.exists?(att.id)
    end
  end
end
