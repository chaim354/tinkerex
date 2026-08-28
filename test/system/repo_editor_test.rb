require "application_system_test_case"
require "support/git_repo_fixture"

# The EDITABLE CodeMirror 6 view, in a real browser — the only tier that can see it.
#
# WHY THIS FILE HAS TO EXIST, and it is not the same reason code_viewer_test.rb exists. That one
# guards a viewer whose whole job is client-side; this one guards a WRITE. The Ruby suite already
# drives `PATCH /files/:id` directly (test/integration/web/repo_edit_flow_test.rb), so the endpoint
# is pinned — what no request test can say is whether anything on the page ever calls it. CLAUDE.md
# §14d records exactly that gap costing nine days: a `data-controller` name that resolves to
# nothing is a SILENT no-op, no error and no console warning, while the endpoint's own request test
# stays green throughout. test/stimulus_hygiene_test.rb proves the identifier RESOLVES; only a
# browser proves the editor mounted EDITABLE and that its Save button reaches the door.
#
# IT SAVES TWICE, DELIBERATELY. One save cannot see the defect this design is most likely to
# acquire: `base_token` is checked server-side, so an editor that never rolls its token forward
# works exactly once and then 409s forever. The second save is the whole guard — mutation-checked
# by deleting the roll-forward line, which turns it red with the conflict message.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, on code_viewer_test.rb's precedent and for its reason: the
# editor must write REAL BYTES back through the port into a REAL git working tree, and a tmpdir
# plus one scan is the cheapest way there. GitRepoFixture#library_root goes through
# `use_fresh_share_library!`, which owns its own teardown. This is NOT a backend-coverage test and
# must not become one — Save on the other two backends is pinned by RepoEditAmbientBackendTest.
class RepoEditorTest < ApplicationSystemTestCase
  include GitRepoFixture

  BODY = "line one\nline two\n".freeze

  setup do
    @user = sign_in_as("repo-editor@example.com")
    @node = seed_repo_file!("notes.md", BODY)
    @path = File.join(library_root, "demo", "notes.md")
  end

  def open_editor
    visit file_path(@node.node_id)
    assert_selector ".cm-editor", wait: 10 # the bundle loaded, parsed and mounted
  end

  # READS THE TWO EDITABILITY FACTS OFF THE LIVE EditorState rather than off the DOM, for
  # code_viewer_test.rb's stated reason: the DOM can only show one of them. `EditorView.editable`
  # is what puts the contenteditable there; `EditorState.readOnly` is what refuses a document
  # change, and nothing a browser renders distinguishes a read-only view from one that merely has
  # no focus. Asking each separately is what lets a mutation of either go red on its own line.
  def editability_facts
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("codemirror").then((cm) => {
        const view = cm.EditorView.findFromDOM(document.querySelector(".cm-content"))
        done({ readOnly: view.state.readOnly, editable: view.state.facet(cm.EditorView.editable) })
      }).catch((e) => done({ error: String(e) }))
    JS
  end

  # Types at the end of the first line and clicks Save. `:end` first because a click lands the
  # caret at whatever x-coordinate it hit — the marker's POSITION is not what any assertion here
  # is about, but "somewhere inside the file" is, and this makes that true without asserting it.
  def type_and_save(marker)
    content = find(".cm-content")
    content.click
    content.send_keys(:end, marker)
    click_on "Save"
  end

  test "a file in a repository opens editable, saves, and the bytes reach the working tree" do
    open_editor

    # THE MOUNT IS EDITABLE — the fact no Ruby test can reach, and the one thing that separates
    # this controller from codeview. Both facets, because either alone would leave the other free
    # to regress silently.
    assert_equal({ "readOnly" => false, "editable" => true }, editability_facts)
    assert_selector ".cm-content[contenteditable=true]"
    # The fallback is REMOVED, not hidden — the same contract codeview has. Leaving it would show
    # the file twice, once uneditable.
    assert_no_selector "pre.preview-text"

    type_and_save("FIRST")
    assert_selector ".editor-status", text: "Saved"

    # THE BYTES ON DISK, not the page's own idea of them. The editor could report "Saved" over a
    # request that never happened; the working tree is the thing git will be asked to commit.
    assert_includes File.read(@path), "FIRST"

    # A SECOND SAVE, WHICH IS THE TOKEN ROLL-FORWARD'S ONLY WITNESS. Without
    # `this.baseTokenValue = body.content_token ?? …` the editor sends the token it LOADED with,
    # the server correctly calls it stale, and this line reports the 409 message instead.
    type_and_save("SECOND")
    assert_selector ".editor-status", text: "Saved"
    assert_includes File.read(@path), "SECOND"
    assert_includes File.read(@path), "FIRST"

    # SURVIVES A RELOAD, which is what makes the two assertions above about a SAVE rather than
    # about a buffer: the page is rebuilt from the bytes the port reads back.
    open_editor
    assert_selector ".cm-content", text: "FIRST"
    assert_selector ".cm-content", text: "SECOND"

    assert_no_console_errors
  end

  # THE NEGATIVE CASE, AND WITHOUT IT THE TEST ABOVE PROVES ONLY "CodeMirror MOUNTS". A file
  # outside a working tree must keep the READ-ONLY controller — that is what makes "editing appears
  # exactly where committing could" an observable property of the page rather than a claim in
  # FilesController#show's comment. Mutating @editable to a bare `true` turns this red and leaves
  # the case above green.
  test "a file outside a repository still opens in the read-only viewer" do
    loose = seed_plain_file!("loose.md", "nothing to see\n")
    visit file_path(loose.node_id)
    assert_selector ".cm-editor", wait: 10

    assert_equal({ "readOnly" => true, "editable" => false }, editability_facts)
    assert_no_selector ".editor-bar"
    assert_no_button "Save"

    assert_no_console_errors
  end
end
