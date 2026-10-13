require "test_helper"
require "support/public_fixture"
require "support/git_repo_fixture"

module Web
  # RENAME AND MOVE TO FOLDER FROM THE BROWSER (F; user stories 1.3 and 4.7 were `rough` for the
  # lack of them). Both are Maker::MoveNode behind two member routes: a collision and a bad name
  # answer the page with a sentence, not a 500, and a node inside a git working tree is offered
  # neither and refused by both (docs/invariants/git-editing.md).
  #
  # A FRESH SHARE LIBRARY ON EVERY LEG, PINNED FIRST. A rename here has to reach a REAL file through
  # the port, so the fixtures are create_node!/make_dir!/make_file!, which write the entry under
  # @root; a bare `nodes.create!` leaves a NULL storage_path that no port verb can act on, and on
  # the ambient s3 or chunk_remote leg it would reach a stub bucket or a live sync server instead.
  # `@library = @root` is what keeps GitRepoFixture#library_root on the SAME directory: left nil it
  # mints a second library and re-pins the port to it, and every fixture above goes missing.
  class FilesRenameMoveTest < ActionDispatch::IntegrationTest
    include PublicFixture
    include GitRepoFixture

    setup do
      @root = use_fresh_share_library!
      @library = @root
      @user = make_owner!(handle: "ada")
      sign_in_as(@user)
      @dir = create_node!(@user, node_id: SecureRandom.uuid, name: "laser", kind: "dir")
      @docs = make_dir!(@user, "docs", @dir)
      @file = make_file!(@user, "part.stl", @dir)
    end

    # §14d: a form_with with no model and no scope has a blank object_name, and a test that PATCHes
    # a Ruby hash cannot see a field name the controller does not read. So the RENDERED names are
    # what is asserted, on both surfaces, and the chooser's starting folder with them.
    test "the inspector and the file page offer Rename and Move with the field names the controller reads" do
      { inspector_file_path(@file.node_id) => "library", file_path(@file.node_id) => "file" }.each do |page, back|
        get page
        assert_response :success
        rename = rename_file_path(@file.node_id)
        move = move_file_path(@file.node_id)
        assert_select "form[action=?] input[type=hidden][name='_method'][value='patch']", rename
        assert_select "form[action=?] input[type=text][name='name'][value='part.stl']", rename
        assert_select "form[action=?] input[type=hidden][name='return_to'][value=?]", rename, back
        assert_select "form[action=?] input[type=hidden][name='_method'][value='patch']", move
        assert_select "form[action=?] input[type=hidden][name='parent_node_id'][value=?]", move, @dir.node_id
        assert_select "form[action=?] input[type=hidden][name='return_to'][value=?]", move, back
        assert_select "form[action=?] .ff-path", move, text: "/laser"
      end
    end

    test "rename changes the name on disk and in the catalog, keeps the node, and lands on the file" do
      patch rename_file_path(@file.node_id), params: { name: "bracket.stl" }

      assert_redirected_to file_path(@file.node_id)
      assert_equal "Renamed to bracket.stl.", flash[:notice]
      assert_equal [ @file.node_id ], @user.nodes.present.where(name: "bracket.stl").pluck(:node_id),
                   "a rename must keep the node_id, or every attachment on it is orphaned (§14a)"
      assert_equal @dir.node_id, @file.reload.parent_node_id
      assert @root.join("laser/bracket.stl").file?
      assert_not @root.join("laser/part.stl").exist?
    end

    test "a rename onto a name already in the folder is refused with a sentence, not a 500" do
      make_file!(@user, "taken.stl", @dir)

      patch rename_file_path(@file.node_id), params: { name: "taken.stl" }

      assert_redirected_to file_path(@file.node_id)
      assert_equal "Something named taken.stl is already in this folder.", flash[:alert]
      follow_redirect!
      assert_select ".flash-alert", text: /already in this folder/
      assert_equal "part.stl", @file.reload.name
      assert @root.join("laser/part.stl").file?
    end

    test "a name that is not a single path segment is refused with Maker::MoveNode's own reason" do
      patch rename_file_path(@file.node_id), params: { name: "../escape.stl" }

      assert_redirected_to file_path(@file.node_id)
      assert_match(/not a valid file name/, flash[:alert].to_s)
      assert_equal "part.stl", @file.reload.name
    end

    # THE DOOR'S HALF OF THE NAME CHECK (§14b): a rename MINTS a leaf name, so it asks the library's
    # reserved namespace as well as the syntax. On share the port would refuse these anyway, as a
    # "File not found." about a file in plain sight; on chunk_remote nothing downstream refuses a
    # name at all, which is why the answer has to come from here.
    test "a name the library keeps for itself is refused at the door" do
      [ ".git", ".trash", ".DS_Store" ].each do |name|
        patch rename_file_path(@file.node_id), params: { name: }

        assert_redirected_to file_path(@file.node_id)
        assert_match(/kept for the library's own files/, flash[:alert].to_s, name)
        assert_equal "part.stl", @file.reload.name, name
      end
    end

    # Maker::MoveNode reads a blank name as "keep the name", which is right for a move and wrong for
    # a rename: an emptied field would report "Renamed" and change nothing.
    test "a blank name is refused rather than read as no change" do
      patch rename_file_path(@file.node_id), params: { name: "   " }

      assert_match(/Type the new name/, flash[:alert].to_s)
      assert_equal "part.stl", @file.reload.name
    end

    test "move puts the file in the chosen folder, on disk and in the catalog" do
      patch move_file_path(@file.node_id), params: { parent_node_id: @docs.node_id }

      assert_redirected_to file_path(@file.node_id)
      assert_equal "Moved part.stl to docs.", flash[:notice]
      @file.reload
      assert_equal [ "part.stl", @docs.node_id ], [ @file.name, @file.parent_node_id ]
      assert @root.join("laser/docs/part.stl").file?
      assert_not @root.join("laser/part.stl").exist?
    end

    # "" IS WHAT THE CHOOSER WRITES FOR THE LIBRARY ROOT (lib/file_chooser.js), so it is the one
    # spelling of "the root" this door must accept.
    test "an empty parent is the library root, the chooser's own answer for it" do
      patch move_file_path(@file.node_id), params: { parent_node_id: "" }

      assert_equal "Moved part.stl to the library root.", flash[:notice]
      assert_nil @file.reload.parent_node_id
      assert @root.join("part.stl").file?
    end

    # A MISSING KEY IS NOT THE ROOT. Share#move's own header records that a nil parent cannot tell
    # "move to the root" from "the caller forgot", and guessing the root sends the file to the top
    # of the library.
    test "a move with no parent at all is refused, never read as the root" do
      patch move_file_path(@file.node_id), params: {}

      assert_redirected_to file_path(@file.node_id)
      assert_match(/Choose a folder/, flash[:alert].to_s)
      assert_equal @dir.node_id, @file.reload.parent_node_id
    end

    test "a move onto a name already in the destination is refused with a sentence" do
      make_file!(@user, "part.stl", @docs)

      patch move_file_path(@file.node_id), params: { parent_node_id: @docs.node_id }

      assert_redirected_to file_path(@file.node_id)
      assert_equal "Something named part.stl is already in docs.", flash[:alert]
      assert_equal @dir.node_id, @file.reload.parent_node_id
      assert @root.join("laser/part.stl").file?
    end

    test "the inspector's forms land back in the Library, in the folder the file is in now" do
      patch move_file_path(@file.node_id), params: { parent_node_id: @docs.node_id, return_to: "library" }
      assert_redirected_to files_path(folder: @docs.node_id, selected: @file.node_id)

      patch rename_file_path(@file.node_id), params: { name: "bracket.stl", return_to: "library" }
      assert_redirected_to files_path(folder: @docs.node_id, selected: @file.node_id)
    end

    # A FOLDER RENAME IS A MOVE OF THE FOLDER'S OWN ROW: the node keeps its id, and the parent edge
    # its children hang from is that id, so they come along. Landing inside the folder, because a
    # folder has no file page to land on.
    test "a folder can be renamed, keeping its node and its children" do
      patch rename_file_path(@dir.node_id), params: { name: "laser-cut" }

      assert_redirected_to files_path(folder: @dir.node_id)
      assert_equal "laser-cut", @dir.reload.name
      assert_equal [ @docs.node_id, @file.node_id ].sort,
                   @user.nodes.present.where(parent_node_id: @dir.node_id).pluck(:node_id).sort
      assert @root.join("laser-cut/part.stl").file?
      assert_not @root.join("laser").exist?
    end

    # MAKER::MOVENODE LEAVES THE CYCLE GUARD TO ITS FIRST CALLER THAT CAN PASS A DIRECTORY, and this
    # door is that caller. Without it share's rename() answers EINVAL, which this controller maps to
    # the RETRYABLE "Couldn't reach your library": the wrong sentence, inviting a retry that can
    # never succeed. The last move is the control: the guard refuses a cycle, not every folder.
    test "a folder cannot be moved into itself or below itself, and can be moved anywhere else" do
      [ @dir, @docs ].each do |target|
        patch move_file_path(@dir.node_id), params: { parent_node_id: target.node_id }

        assert_equal "A folder can't be moved inside itself.", flash[:alert], target.name
        assert_nil @dir.reload.parent_node_id, target.name
        assert @root.join("laser/docs").directory?, target.name
      end

      archive = create_node!(@user, node_id: SecureRandom.uuid, name: "archive", kind: "dir")
      patch move_file_path(@dir.node_id), params: { parent_node_id: archive.node_id }
      assert_equal "Moved laser to archive.", flash[:notice]
      assert_equal archive.node_id, @dir.reload.parent_node_id
      assert @root.join("archive/laser/part.stl").file?
    end

    # BYTES GIT OWNS NEVER GO THROUGH THE PORT (git-editing.md), and a rename git did not make is a
    # deletion plus an untracked file to it. The view hiding the forms is the courtesy; the refusal
    # in both actions is the rule. The first GET is the control that keeps the two `count: 0`
    # assertions from passing over a panel that renders no forms for anyone.
    test "a file inside a git working tree offers neither, and both doors refuse it" do
      repo = make_repo!(name: "firmware", files: { "main.c" => "int main(void) { return 0; }\n" })
      inside = @user.nodes.present.find_by!(name: "main.c", parent_node_id: repo.node_id)

      get inspector_file_path(@file.node_id)
      assert_select "form[action=?]", rename_file_path(@file.node_id), { count: 1 }
      [ inspector_file_path(inside.node_id), file_path(inside.node_id) ].each do |page|
        get page
        assert_response :success
        assert_select "form[action=?]", rename_file_path(inside.node_id), { count: 0 }, page
        assert_select "form[action=?]", move_file_path(inside.node_id), { count: 0 }, page
      end

      patch rename_file_path(inside.node_id), params: { name: "app.c" }
      assert_redirected_to file_path(inside.node_id)
      assert_match(/inside a repository/, flash[:alert].to_s)
      patch move_file_path(inside.node_id), params: { parent_node_id: @docs.node_id }
      assert_redirected_to file_path(inside.node_id)
      assert_match(/inside a repository/, flash[:alert].to_s)

      inside.reload
      assert_equal [ "main.c", repo.node_id ], [ inside.name, inside.parent_node_id ]
      assert @root.join("firmware/main.c").file?
    end

    test "another user's file is not found, and is left alone" do
      other = make_owner!(handle: "bob")
      theirs = create_node!(other, node_id: SecureRandom.uuid, name: "theirs.stl", kind: "file")

      patch rename_file_path(theirs.node_id), params: { name: "mine.stl" }
      assert_redirected_to files_path
      assert_equal "File not found.", flash[:alert]
      patch move_file_path(theirs.node_id), params: { parent_node_id: "" }
      assert_redirected_to files_path

      assert_equal [ "theirs.stl", nil ], [ theirs.reload.name, theirs.parent_node_id ]
    end
  end
end
