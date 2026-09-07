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

    # WHERE THE FILE IS ON THE SHARE — story 2.10's whole complaint. The page showed Name, Size,
    # Type and Modified and never once said where the thing lives, so the way back to LightBurn was
    # to remember the folder. Root-relative and NOT a URL: this app cannot know the mount's name on
    # the maker's own machine, and inventing an smb:// would be a guess dressed as a fact.
    #
    # THE CONTROLLER AND THE VALUE SIT ON THE `dd` ITSELF, so both selectors below are ATTRIBUTE
    # QUALIFIERS (`dd[...]`) and not descendant combinators (`dd [...]`). A space there asks for a
    # child carrying the attribute, which nothing does — it is the shape that passes vacuously in
    # the other direction, so it is written tightly on purpose.
    test "the meta list carries the file's library path, with a copy button over it" do
      cad = @user.nodes.create!(node_id: "d-cad", name: "cad", kind: "dir",
                                mtime: 1_000_000_000, size: 0)
      deep = @user.nodes.create!(node_id: "d-lids", name: "lids", kind: "dir",
                                 parent_node_id: cad.node_id, mtime: 1_000_000_000, size: 0)
      node = @user.nodes.create!(node_id: "n-lid", name: "lid.lbrn2", kind: "file",
                                 parent_node_id: deep.node_id, mtime: 1_000_000_000, size: 12)

      get file_path(node.node_id)

      assert_response :success
      assert_select "dl.meta dt", text: "Path"
      assert_select "dl.meta dd .file-path-value", text: "cad/lids/lid.lbrn2"
      assert_select "dl.meta dd[data-controller~=?]", "copy"
      assert_select "dl.meta dd[data-copy-text-value=?]", "cad/lids/lid.lbrn2"
      assert_select "dl.meta dd button[data-action=?]", "copy#copy", text: "Copy"
    end

    test "a file at the library root is its own path" do
      get file_path(@node.node_id)
      assert_select "dl.meta dd .file-path-value", text: "coaster.lbrn2"
    end

    # A BROKEN ANCESTOR CHAIN IS "WE DO NOT KNOW", NOT A ROOT-LEVEL FILE. Maker::LibraryTree
    # #path_for answers nil for a tombstoned or missing ancestor; rendering the bare name there
    # would say the file sits at the top of the library, which is a confident lie about where to
    # find it. No row at all is the honest answer.
    test "a file whose folder chain is broken shows no path rather than a wrong one" do
      orphan = @user.nodes.create!(node_id: "n-orphan", name: "stray.svg", kind: "file",
                                   parent_node_id: "d-gone", mtime: 1_000_000_000, size: 1)
      get file_path(orphan.node_id)
      assert_select "dl.meta dt", text: "Path", count: 0
    end

    # ---- END OF S4-3 TASK C's ADDITIONS -------------------------------------------------------
    # Task D (Save to library) appends BELOW this line, so the two tasks' tests never interleave.
  end
end
