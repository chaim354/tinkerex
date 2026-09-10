require "test_helper"

module Web
  # MAKING A TEXT FILE WHERE YOU ARE STANDING (2026-09-10, the Files-page affordances plan, Task 4).
  # A door of its own rather than a parameter on FilesController#create: that action's job is bytes
  # off a multipart form, and a create-that-takes-no-bytes riding it would need a third arm with its
  # own refusals.
  #
  # A FRESH SHARE LIBRARY PER TEST, PINNED BEFORE ANY FIXTURE RUNS, for the reason
  # readme_edit_test.rb records at its own setup: these tests write real bytes through the port, and
  # on the ambient s3 and chunk_remote legs the folder mkdir hits the stub bucket and the sync
  # server's provisioning. Pinning share is what makes the three legs report identical counts.
  class TextFileCreationTest < ActionDispatch::IntegrationTest
    PASSWORD = "correct horse battery staple".freeze

    setup do
      @root = use_fresh_share_library!
      @user = User.create!(email: "txt@example.com", password: PASSWORD, confirmed_at: Time.current)
      post user_session_path, params: { user: { email: @user.email, password: PASSWORD } }
    end

    teardown { FileLayer.reset!; FileUtils.remove_entry(@root) if @root&.exist? }

    # The house mutation/stub helper (readme_edit_test.rb, project_repo_card_test.rb and
    # project_folder_listing_test.rb carry the same body; there is no shared copy in test_helper.rb,
    # and this suite has no Object#stub — Minitest 6 dropped minitest/mock). Replaces a SINGLETON
    # method for the block's duration, so an INHERITED one is removed again rather than left behind.
    def replacing(owner, name, replacement)
      mod = owner.singleton_class
      own = mod.instance_methods(false).include?(name)
      original = mod.instance_method(name)
      mod.define_method(name, &replacement)
      yield
    ensure
      own ? mod.define_method(name, original) : mod.remove_method(name)
    end

    test "it creates an empty file and lands on its page" do
      post files_text_files_path, params: { name: "bench-notes.txt" }
      node = @user.nodes.present.find_by(name: "bench-notes.txt")
      refute_nil node, "no node was created"
      assert_redirected_to file_path(node.node_id)
    end

    test "a reserved name is refused, and nothing is written" do
      # BOTH GUARDS, because a name-minting door asks two questions (§14b): `valid_leaf_name?` for
      # syntax and `ReservedNames.reserved?` for the library's own namespace. The upload door
      # shipped with NEITHER and was the weakest door in the app.
      before = @user.nodes.count
      post files_text_files_path, params: { name: ".trash" }
      assert_response :unprocessable_entity
      assert_equal before, @user.nodes.count, "a refused name still wrote a row"
    end

    test "a traversing name is refused" do
      before = @user.nodes.count
      post files_text_files_path, params: { name: "../escape.txt" }
      assert_response :unprocessable_entity
      assert_equal before, @user.nodes.count
    end

    # --- the editor, outside a repository (Task 5) ----------------------------------------------

    test "the editor renders for a text file outside a repository" do
      post files_text_files_path, params: { name: "notes.txt" }
      node = @user.nodes.present.find_by!(name: "notes.txt")

      get file_path(node.node_id)

      assert_response :success
      assert_select "[data-controller~=editor]", 1, "no editor rendered outside a repo"
    end

    test "a save round-trips and the node id survives it" do
      # `replace: true` REUSES THE NODE. A save written as delete-then-create passes any
      # bytes-oriented assertion while orphaning every attachment, BOM link and tag — §14a's
      # landmine, which errors nowhere and logs nothing. The node id is what they are keyed on.
      post files_text_files_path, params: { name: "notes.txt" }
      node = @user.nodes.present.find_by!(name: "notes.txt")
      token = FileLayer.current.stat(@user, node_id: node.node_id).content_token

      patch file_path(node.node_id), params: { content: "bench notes\n", base_token: token }
      assert_response :success

      assert_equal 1, @user.nodes.present.where(name: "notes.txt").count,
                   "a delete-then-create leaves the old row tombstoned and a new one beside it"
      assert_equal node.node_id, @user.nodes.present.find_by!(name: "notes.txt").node_id
      assert_equal "bench notes\n", FileLayer.current.read(@user, node_id: node.node_id)
    end

    test "no pending git edit is recorded outside a working tree" do
      # THE HALF THAT NEEDED NO BRANCH. Maker::TextSave records a Maker::RepoEdit only when a repo
      # root is NAMED and the backend holds the working tree, so this door passing nil is the whole
      # difference between a file inside a repository and one outside it. Recording one here would
      # put a row in the commit box for a repository that does not exist.
      post files_text_files_path, params: { name: "notes.txt" }
      node = @user.nodes.present.find_by!(name: "notes.txt")
      token = FileLayer.current.stat(@user, node_id: node.node_id).content_token

      patch file_path(node.node_id), params: { content: "bench notes\n", base_token: token }

      assert_response :success
      assert_empty Maker::RepoEdit.where(user: @user, node_id: node.node_id)
    end

    test "the no-history note names the trade on a library that keeps none" do
      post files_text_files_path, params: { name: "notes.txt" }
      node = @user.nodes.present.find_by!(name: "notes.txt")

      get file_path(node.node_id)

      if FileLayer.current.capabilities.versioned?
        assert_select ".no-history-note", 0, "a versioned library must not claim it keeps no history"
      else
        assert_select ".no-history-note", text: /keeps no history for this file/
      end
    end

    test "the note is keyed on versioned?, so a library that keeps history shows none" do
      # THE OTHER ARM, AND IT IS UNREACHABLE WITHOUT THIS STUB. Every case in this class pins a
      # share library (see the class comment), so on all three legs the branch above takes its
      # `else` — the assertion that a versioned library says nothing would never once run, which is
      # §14e's vacuous guard with a conditional in place of a skip. What is being asserted is a fact
      # about the KEY rather than about a backend, so the key is what gets stubbed: chunk_remote's
      # own answer is then this test's answer, on every leg, deterministically.
      post files_text_files_path, params: { name: "notes.txt" }
      node = @user.nodes.present.find_by!(name: "notes.txt")
      versioned = FileLayer.current.capabilities.with(versioned: true)

      replacing(FileLayer.current, :capabilities, -> { versioned }) do
        get file_path(node.node_id)
      end

      assert_response :success
      assert_select "[data-controller~=editor]", 1, "the editor must still be here to warn about"
      assert_select ".no-history-note", 0, "a versioned library must not claim it keeps no history"
    end

    # THE PARENT WENT AWAY BETWEEN OPENING THE FORM AND SUBMITTING IT. `parent_node_id` rides as a
    # hidden field, so this needs no tampering: another tab's Delete, a device push plus changelog
    # pull, or an ordinary scan reconcile will do it.
    #
    # `FileLayer::NotFound` IS A SIBLING OF THE TWO THIS DOOR ALREADY RESCUES, not a subclass, and
    # this controller does not inherit FilesController's `rescue_from` — ApplicationController has
    # none. Un-rescued, the exception escapes the request: a 500 with the typed name lost.
    test "a parent that has gone is refused, not a 500" do
      dir = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "parts")
      @user.nodes.find_by!(node_id: dir.node_id).update!(deleted: true, storage_path: nil)

      post files_text_files_path, params: { name: "notes.txt", parent_node_id: dir.node_id }

      assert_response :not_found
      # THE MAKER'S SENTENCE, NOT THE PORT'S. The port's own message names a raw node id
      # (`parent "<uuid>" is not a live directory`), which is not something to put in front of
      # someone — so the assertion is on the FLASH, the text a maker actually reads. The id still
      # appears in the re-rendered form's hidden field and the Cancel link, which is correct: the
      # form comes back populated so the typed name is not lost.
      flash_text = css_select(".flash-alert .flash-text").map(&:text).join(" ")
      assert_match(/no longer here/i, flash_text)
      refute_match(dir.node_id, flash_text, "a raw node id reached the maker's message")
    end

    # ---- WHAT IS EDITABLE OUTSIDE A REPOSITORY (narrowed 2026-09-10) -----------------------------
    #
    # THE REFUSAL EXISTS BECAUSE THERE IS NO UNDO. Inside a working tree git is the undo, so any text
    # file stays editable there — that is the behaviour this door inherited and must not remove.
    # OUTSIDE one a save replaces the file with nothing to go back to, so the set is narrowed to the
    # two extensions a maker writes PROSE in. A `.rb`, a `.json` or a `.gcode` on a NAS is something
    # a tool wrote; opening it in a writable editor with no history is a worse offer than showing it.

    test "a .txt outside a repository is editable" do
      post files_text_files_path, params: { name: "notes.txt" }
      node = @user.nodes.present.find_by!(name: "notes.txt")
      get file_path(node.node_id)
      assert_select "[data-controller~=editor]", 1, "a .txt is what this door exists to make"
    end

    test "a .md outside a repository is editable" do
      post files_text_files_path, params: { name: "notes.md" }
      node = @user.nodes.present.find_by!(name: "notes.md")
      get file_path(node.node_id)
      assert_select "[data-controller~=editor]", 1
    end

    test "another text file outside a repository is read-only, not editable" do
      post files_text_files_path, params: { name: "sketch.scad" }
      node = @user.nodes.present.find_by!(name: "sketch.scad")

      get file_path(node.node_id)
      assert_response :success
      assert_select "[data-controller~=editor]", 0, "a .scad outside a repo has no undo behind it"
      # AND IT IS STILL SHOWN. Narrowing what is WRITABLE must not narrow what is READABLE — the
      # read-only viewer is the whole point of the distinction.
      assert_select "[data-controller~=codeview]", 1, "the read-only viewer must still render it"
    end

    test "the server refuses the save too, not just the editor" do
      # THE SERVER IS THE ENFORCER. Hiding the editor is the courteous half; a door that only hid it
      # would still accept a hand-rolled PATCH, which is the shape §14e records for the size cap.
      post files_text_files_path, params: { name: "sketch.scad" }
      node = @user.nodes.present.find_by!(name: "sketch.scad")
      token = FileLayer.current.stat(@user, node_id: node.node_id).content_token

      patch file_path(node.node_id), params: { content: "cube(1);", base_token: token }
      assert_response :unprocessable_entity
      assert_equal "", FileLayer.current.read(@user, node_id: node.node_id), "the file was written anyway"
    end
  end
end
