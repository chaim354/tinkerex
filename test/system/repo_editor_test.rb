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

  # True when the editor's leave-guard would make the browser ask. WebDriver accepts every
  # beforeunload prompt on its own, so the prompt cannot be waited for; the guard's answer to a
  # cancelable `beforeunload` dispatched in the page — preventing it — is what the browser acts on.
  GUARD_HOLDS = '(() => { const e = new Event("beforeunload", { cancelable: true }); ' \
                "window.dispatchEvent(e); return e.defaultPrevented })()".freeze

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

  # Makes the editor's next PATCH answer however `respond` (a JS expression) says, and leaves every
  # other request alone — the page's own GETs must still reach the server. The states below are ones
  # this server cannot be made to produce on demand (a dropped connection, a proxy's HTML 500), and
  # what is being pinned is what the EDITOR does with them, so the fetch is replaced in the page
  # rather than the server broken (repo_history_test.rb#render_history's reasoning).
  def answer_saves_with(respond)
    page.execute_script(<<~JS)
      const real = window.fetch
      window.fetch = (url, opts = {}) => opts.method === "PATCH" ? (#{respond}) : real(url, opts)
    JS
  end

  # The unsaved edit these cases leave behind would hold the next navigation at the browser's
  # "Leave site?" prompt; this is the editor's own stand-down, the one history's Restore sends.
  def discard_unsaved_edit
    page.execute_script("document.dispatchEvent(new CustomEvent('editor:discard'))")
  end

  # A SAVE THAT FAILS SAYS SO, AND THE EDIT STAYS (UX audit B4). The save was a try/finally with no
  # catch, so a dropped connection threw past the status line and left "Saving…" on screen for good
  # over an edit that never reached the disk. The two answers below are the two ways that happened:
  # no answer at all, and an answer `res.json()` cannot read.
  #
  # MUTATION-CHECKED (2026-11-02): with the fetch's own `catch` removed from editor_controller.js#save
  # the first case goes RED ("Saving…" stays, no `.flash-alert`); with `.catch(() => null)` removed
  # from the `res.json()` the second goes RED the same way. Each restored, both green.
  test "a save the server never answers says Not saved and keeps the edit" do
    open_editor
    answer_saves_with('Promise.reject(new TypeError("Failed to fetch"))')
    type_and_save("LOST")

    assert_selector ".editor-status.flash.flash-alert", text: "Not saved. The server could not be reached"
    assert_no_selector ".editor-status", text: "Saving"
    assert_selector ".cm-content", text: "LOST" # the edit is still in the buffer
    assert_selector ".editor-bar button:not([disabled])", text: "Save"
    refute_includes File.read(@path), "LOST"
    discard_unsaved_edit
    assert_no_console_errors
  end

  test "an HTML error page in answer to a save says Not saved, never Saving forever" do
    open_editor
    answer_saves_with('Promise.resolve(new Response("<html><body>Internal Server Error</body></html>", ' \
                      '{ status: 500, headers: { "Content-Type": "text/html" } }))')
    type_and_save("LOST")

    assert_selector ".editor-status.flash.flash-alert", text: "Not saved. The server had a problem"
    assert_no_selector ".editor-status", text: "500" # a status code is a wire code, not a sentence
    assert_selector ".editor-bar button:not([disabled])", text: "Save"
    discard_unsaved_edit
    assert_no_console_errors
  end

  # A RAILS EXCEPTION PAGE ANSWERED AS JSON IS NOT THE SERVER'S SENTENCE. With `Accept:
  # application/json`, an unhandled exception comes back from Rails' own exception app as
  # `{"status":500,"error":"Internal Server Error"}` — an `error` key, but not one written for a
  # maker. Only FilesController#render_save_error's `{ ok: false, error }` is printed; this one gets
  # the editor's own 500 sentence.
  #
  # MUTATION-CHECKED (2026-11-02): with editor_controller.js#refusal trusting any `body.error` again
  # (`const said = body?.error`), the status reads "Not saved. Internal Server Error" — RED;
  # restored, green.
  test "a JSON exception answer reads as the editor's own 500 sentence, not Rails' error string" do
    open_editor
    answer_saves_with('Promise.resolve(new Response(JSON.stringify({ status: 500, error: "Internal Server Error" }), ' \
                      '{ status: 500, headers: { "Content-Type": "application/json" } }))')
    type_and_save("LOST")

    assert_selector ".editor-status.flash.flash-alert", text: "Not saved. The server had a problem"
    assert_no_selector ".editor-status", text: "Internal Server Error"
    discard_unsaved_edit
    assert_no_console_errors
  end

  # THE STALE ANSWER IS THE SERVER'S SENTENCE, A RELOAD BUTTON, AND WHAT RELOADING COSTS. The file
  # moved on under the editor — on share `stat` answers from the catalog row, so a scan that saw a
  # desktop edit is a new `content_hash` there — and FilesController#update refuses the save (409)
  # rather than overwrite the newer bytes. The maker is told the reload discards their edit, and the
  # Reload button does not then ask again in the browser's words: pressing it IS that choice. The
  # guard's answer is read from a document click listener, which runs after the button's own, and
  # kept in sessionStorage across the reload that follows.
  #
  # MUTATION-CHECKED (2026-11-02): with `this.discarded = true` removed from the Reload button's
  # handler (editor_controller.js#report), the recorded answer is "true" — RED; restored, green.
  test "a save against a file that changed says so and offers Reload" do
    open_editor
    File.write(@path, "edited elsewhere\n")
    @node.update_columns(content_hash: Digest::SHA256.hexdigest("edited elsewhere\n"))
    type_and_save("MINE")

    assert_selector ".editor-status.flash-alert", text: "This file changed since you opened it."
    assert_selector ".editor-status", text: "Reloading discards the edit you made here."
    assert_equal "edited elsewhere\n", File.read(@path), "the stale save wrote anyway"
    assert page.evaluate_script(GUARD_HOLDS), "the refused edit is not guarded, so this case proves nothing"

    page.execute_script(<<~JS)
      sessionStorage.removeItem("guard-after-reload-click")
      document.addEventListener("click", () =>
        sessionStorage.setItem("guard-after-reload-click", String(#{GUARD_HOLDS})))
    JS
    within(".editor-status") { click_on "Reload" }
    assert_selector ".cm-content", text: "edited elsewhere", wait: 10
    assert_equal "false", page.evaluate_script("sessionStorage.getItem('guard-after-reload-click')")
    assert_no_selector ".cm-content", text: "MINE"
    assert_no_console_errors(ignoring: [ /status of 409/ ])
  end

  # AN UNSAVED EDIT IS ASKED ABOUT BEFORE A VISIT LEAVES IT, AND A SAVED ONE IS NOT. Both halves of
  # the guard: a Turbo visit (the crumb is an ordinary Turbo link on every file page) gets one
  # confirm, and a full navigation gets the browser's beforeunload prompt, read here as the guard's
  # answer to a dispatched `beforeunload` because WebDriver accepts the real prompt on its own.
  #
  # MUTATION-CHECKED (2026-11-02): with the `turbo:before-visit` listener removed from
  # editor_controller.js#guard, `dismiss_confirm` finds no dialog (Capybara::ModalNotFound) — RED;
  # with the `beforeunload` listener removed, the GUARD_HOLDS assertion — RED. Each restored, green.
  test "an unsaved edit is asked about before a visit leaves it" do
    open_editor
    refute page.evaluate_script(GUARD_HOLDS), "a page with nothing typed asks before leaving"
    content = find(".cm-content")
    content.click
    content.send_keys(:end, "UNSAVED")
    assert page.evaluate_script(GUARD_HOLDS), "a full navigation would leave the unsaved edit unasked"

    question = dismiss_confirm { find("nav.breadcrumb a", match: :first).click }
    assert_equal "Leave this file without saving your changes?", question
    assert_current_path file_path(@node.node_id)
    assert_selector ".cm-content", text: "UNSAVED"

    click_on "Save"
    assert_selector ".editor-status", text: "Saved"
    refute page.evaluate_script(GUARD_HOLDS), "a saved edit still asks before leaving"
    find("nav.breadcrumb a", match: :first).click # saved: nothing to ask about
    assert_no_current_path file_path(@node.node_id)
    assert_no_console_errors
  end

  # THE COMMIT BOX'S DIFF, AND NO REQUEST TEST CAN SEE IT. @codemirror/merge renders through
  # extensions, and CM6's answer to a DUPLICATE @codemirror/state is to IGNORE an extension
  # SILENTLY — no error, no console warning, the editor mounts and the feature is simply absent
  # (CLAUDE.md §14d). The integration suite asserts the page ships the two blob URLs; only a
  # browser can say the diff was built from them.
  #
  # ASSERTS THE CHANGED LINE IS MARKED, NOT MERELY THAT AN EDITOR APPEARED. `.cm-editor` alone
  # would be satisfied by basicSetup with unifiedMergeView dropped on the floor, which is exactly
  # the defect above. `.cm-deletedChunk` is the merge extension's own decoration for HEAD's side
  # of a hunk, so it exists only if the extension ran.
  test "the commit box diffs the working tree against HEAD, in the browser" do
    visit file_path(@node.node_id)
    assert_selector ".cm-editor", wait: 10
    type_and_save("CHANGED")
    assert_selector ".editor-status", text: "Saved"

    root = @user.nodes.present.find_by!(name: "demo", kind: "dir")
    visit repo_commit_path(root.node_id)

    assert_selector "[data-path='notes.md']"
    assert_selector ".commit-diff .cm-editor", wait: 10
    assert_selector ".commit-diff .cm-deletedChunk", wait: 10

    # NO MERGE CONTROLS, and this is the assertion that keeps the box honest rather than a
    # stylistic preference. diffview_controller records the measurement: rejectChunk dispatches a
    # DOCUMENT change that readOnly does not gate, so an enabled control would revert the BUFFER
    # and never the working tree — the maker would watch a change vanish, commit, and find it
    # still on disk. If someone turns mergeControls on, this line is what makes them come back and
    # read why, and the label they will need is "Revert hunk" (never "Reject": `original` is HEAD
    # here, so rejecting a chunk REVERTS the maker's own edit).
    assert_no_selector ".commit-diff .cm-chunkButtons"
    assert_no_button "Reject"

    # THE DIFF IS READ-ONLY, both facets, for the reason the file-page cases give.
    assert_no_selector ".commit-diff .cm-content[contenteditable=true]"

    assert_no_console_errors
  end

  # THE NEGATIVE CASE, AND WITHOUT IT THE TEST ABOVE PROVES ONLY "CodeMirror MOUNTS". Its subject
  # was "a file outside a working tree" until 2026-09-10; the editor stopped asking for a repository
  # on that date (docs/invariants/git-editing.md's Markdown exception, widened to any text file), so
  # that file is now editable and would prove the opposite of what this case is for.
  #
  # WHAT IS STILL READ-ONLY IS A FILE OVER THE SERVER'S CAP, `FilesController::EDITABLE_MAX_BYTES`
  # — the one term left in `@editable` besides "is it text" — so it is the subject now and every
  # assertion below is unchanged. MUTATION-CHECKED 2026-09-10 by dropping `editable?(@node)` from
  # @editable: this case fails at its own `.cm-editor` wait — editor_controller returns early
  # for an over-cap buffer and mounts nothing at all — and the case above stays green, which is
  # the whole job.
  #
  # MANY LINES RATHER THAN ONE LONG ONE: a single 200,000-character line is a pathological
  # CodeMirror document and would be measuring the renderer instead of the gate.
  test "a file over the editable cap still opens in the read-only viewer" do
    body = "filler line, long enough to be worth counting\n" * 5_000
    assert_operator body.bytesize, :>, FilesController::EDITABLE_MAX_BYTES,
                    "the fixture has to be over the cap or this case cannot fail"
    big = seed_plain_file!("huge.md", body)
    visit file_path(big.node_id)
    assert_selector ".cm-editor", wait: 10

    assert_equal({ "readOnly" => true, "editable" => false }, editability_facts)
    assert_no_selector ".editor-bar"
    # EXACT, because the top bar's Upload is a <button> whose title reads "Saves to <folder>", and a
    # button locator matches a title by substring: without it this matched Upload and went red on a
    # page with no Save at all.
    assert_no_button "Save", exact: true

    assert_no_console_errors
  end
end
