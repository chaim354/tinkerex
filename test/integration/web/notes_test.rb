require "test_helper"

module Web
  class NotesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      pin_file_layer_backend("chunk")
      Storage::ChunkStore.reset!
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email:, password: PASSWORD } }
      user
    end

    test "create a note on a file the user owns (HTML)" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "part.stl", kind: "file")
      assert_difference "Maker::Note.count", 1 do
        post file_notes_path("f-1"), params: { note: { body: "print at 0.2mm" } }
      end
      assert_redirected_to file_path("f-1")
      assert_equal "print at 0.2mm", user.maker_notes.last.body.to_plain_text
    end

    test "create a note via JSON returns the new count" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "part.stl", kind: "file")
      user.maker_notes.create!(node_id: "f-1", body: "existing")
      post file_notes_path("f-1"), params: { note: { body: "second" } }, as: :json
      assert_response :created
      assert_equal 2, JSON.parse(response.body)["count"]
    end

    test "a blank body is rejected" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "part.stl", kind: "file")
      assert_no_difference "Maker::Note.count" do
        post file_notes_path("f-1"), params: { note: { body: "" } }
      end
    end

    test "noting a node the user does not own is not found" do
      user = sign_in
      other = User.create!(email: "z@example.com", password: PASSWORD, confirmed_at: Time.current)
      other.nodes.create!(node_id: "theirs", name: "secret.stl", kind: "file")
      assert_no_difference "Maker::Note.count" do
        post file_notes_path("theirs"), params: { note: { body: "sneaky" } }, as: :json
      end
      assert_response :not_found
    end

    test "delete a note" do
      user = sign_in
      user.nodes.create!(node_id: "f-1", name: "part.stl", kind: "file")
      note = user.maker_notes.create!(node_id: "f-1", body: "bye")
      assert_difference "Maker::Note.count", -1 do
        delete note_path(note)
      end
    end

    test "another user's note cannot be deleted" do
      sign_in
      other = User.create!(email: "z2@example.com", password: PASSWORD, confirmed_at: Time.current)
      note = other.maker_notes.create!(node_id: "x", body: "theirs")
      delete note_path(note)
      assert_response :not_found
      assert Maker::Note.exists?(note.id), "another user's note must survive"
    end

    test "the note form renders a Lexxy editor with attachments disabled" do
      user = sign_in
      node = user.nodes.create!(node_id: "n-1", name: "bracket.stl", kind: "file")
      get file_path(node.node_id)
      assert_response :success
      assert_select "lexxy-editor[attachments=?]", "false"
      assert_select "textarea[name=?]", "note[body]", count: 0
    end

    test "a rich note body renders as markup" do
      user = sign_in
      node = user.nodes.create!(node_id: "n-2", name: "bracket.stl", kind: "file")
      post file_notes_path(node.node_id),
           params: { note: { body: "<p>Print at <strong>0.2mm</strong></p>" } }
      follow_redirect!
      assert_select ".note-body strong", text: "0.2mm"
    end
  end
end
