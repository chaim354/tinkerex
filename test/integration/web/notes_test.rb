require "test_helper"

module Web
  class NotesTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      # A hermetic library for this suite. It pinned embedded chunk until Arc D Part 2; with that
      # backend retired it would otherwise run on the AMBIENT one, which on the s3 leg means real
      # Aws calls (the stub is opt-in per file) and on chunk_remote means a live sync server.
      # What these tests are about is the web layer, not which backend holds the bytes.
      @root = use_fresh_share_library!
    end

    teardown do
      FileLayer.reset!
      FileUtils.remove_entry(@root) if @root&.exist?
    end

    def sign_in(email = "maker@example.com")
      user = User.find_by(email:) ||
             User.create!(email:, password: PASSWORD, confirmed_at: Time.current)
      sign_in_web!(user, password: PASSWORD)
    end

    # NotesController had no refusal assertion of its own — roughly seven of the sixteen
    # session-authed controllers did, never as a completeness check (CLAUDE.md §14d). The
    # completeness half now lives in architecture_invariants_test.rb, which reads the callback
    # chain; this is the request that proves the chain actually turns an anonymous visitor away.
    #
    # A POST rather than a GET because NotesController routes no GET at all, and it is the
    # stronger assertion for it: the redirect proves the action never ran. Without the callback
    # `current_user` is nil and `current_user.nodes` raises, so the count alone would not tell a
    # refused write from a crashed one — the 302 is what carries the weight.
    test "creating a note requires a session" do
      assert_no_difference "Maker::Note.count" do
        post file_notes_path("f-1"), params: { note: { body: "anonymous" } }
      end
      assert_redirected_to new_user_session_path
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
