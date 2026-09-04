require "test_helper"

module Web
  # The file page's head and notes (spec §8, PR 2): the format sits beside the name as a badge,
  # and the notes composer is closed until asked for — the same form, the same Lexxy editor, the
  # same field, inside a <details>. The page's actions keep Back as the only ghost button
  # (back_link_test reads it by that selector).
  class FilePageTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @user = User.create!(email: "fp-#{SecureRandom.hex(4)}@example.com",
                           password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
      @node = @user.nodes.create!(node_id: "n-coaster", name: "coaster.lbrn2", kind: "file",
                                  mtime: 1_000_000_000, size: 2_400)
    end

    test "the head shows the format as a badge beside the name" do
      get file_path(@node.node_id)
      assert_response :success
      assert_select ".page-head h1", text: "coaster.lbrn2"
      assert_select ".page-head .badge.file-badge", text: "LBRN2"
      assert_select ".page-actions a.btn.ghost", count: 1, text: "Back"
    end

    test "the notes composer is a closed details that still holds the whole form" do
      get file_path(@node.node_id)
      assert_select ".notes-panel details.composer:not([open]) > summary", text: "Add a note"
      assert_select ".notes-panel details.composer form.note-form[action=?] lexxy-editor[attachments='false']",
                    file_notes_path(@node.node_id)
      assert_select ".notes-panel details.composer form.note-form input[type='submit'][value='Add note']"
      assert_select ".notes-panel", text: /No notes yet\./
    end

    test "a file with no extension gets no badge" do
      bare = @user.nodes.create!(node_id: "n-license", name: "LICENSE", kind: "file", mtime: 1_000_000_000, size: 10)
      get file_path(bare.node_id)
      assert_select ".page-head .file-badge", count: 0
    end
  end
end
