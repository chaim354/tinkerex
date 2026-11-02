require "application_system_test_case"
require "support/git_repo_fixture"

# The file page's history panel, in a real browser — the only tier that can see any of it.
#
# WHY A SYSTEM TEST IS NOT OPTIONAL HERE. The panel is EMPTY at first paint: the server ships a
# mount and four URLs, and every row arrives by fetch afterwards. So a request test cannot see one
# row of it — test/integration/web/repo_history_flow_test.rb proves the endpoints answer, and
# proves nothing about whether anything on the page ever calls them. CLAUDE.md §14d records that
# exact gap costing nine days: a `data-controller` name that resolves to nothing is a SILENT no-op,
# no error and no console warning, while the endpoint's own request test stays green throughout.
# test/stimulus_hygiene_test.rb proves the identifier RESOLVES; only a browser proves the panel
# fetched, rendered, diffed and wrote.
#
# THE HONEST EMPTY STATE IS THE POINT OF THE PANEL, AND IT IS WHAT THE 260-COMMIT CASE BELOW BUYS.
# Path filtering is sparse — 1 of the last 50 commits touched README.md in the measured repository,
# against 28 of all 333 (tinkerex#178, spec part 3) — so "we stopped looking" is the ORDINARY
# answer for a real file, and rendering it as "this file has no history" tells a maker their file
# never changed when it changed 28 times. A fixture small enough for the walk to exhaust cannot
# reach that state at all, which is the shape §15 warns about: an assertion that cannot fail.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, on repo_editor_test.rb's precedent and for its reason: history
# reads a REAL repository through `FileLayer::Share#absolute_path`, so a tmpdir plus one scan is
# the cheapest way to a working tree. GitRepoFixture#library_root goes through
# `use_fresh_share_library!`, which owns its own teardown. This is NOT a backend-coverage test —
# the panel's absence on a backend with no working tree is pinned by the integration suite.
class RepoHistoryTest < ApplicationSystemTestCase
  include GitRepoFixture

  setup { @user = sign_in_as("repo-history@example.com") }

  # True when the editor's leave-guard would make the browser ask: the guard's answer to a cancelable
  # `beforeunload` is to prevent it (editor_controller.js#guard).
  GUARD_HOLDS = '(() => { const e = new Event("beforeunload", { cancelable: true }); ' \
                "window.dispatchEvent(e); return e.defaultPrevented })()".freeze

  # The oids the panel will list, from the same service the endpoint uses. Selecting rows by
  # `data-oid` rather than by their message text is not fussiness: a short_oid is eight hex
  # characters, so `find(".history-row", text: "c0")` can match the OTHER row whenever its abbrev
  # happens to contain "c0" — a test that fails once a month for a reason nobody can reproduce.
  def history_oids(root, rel)
    Maker::Git::History.new(Maker::Git::LocalRepo.open(@user, root)).for_path(rel).entries.map(&:oid)
  end

  # Feeds `history_controller#render` a response directly. THE STATES BELOW ARE ONES THIS
  # DEPLOYMENT CANNOT PRODUCE ON DEMAND: `restorable: false` beside real entries cannot be reached
  # through the server at all today (FilesController#history refuses "no_worktree" before it ever
  # walks), and "unavailable" needs a repository broken in a way a fixture would have to fake. The
  # rules being pinned are the PANEL's, they live in that one method, and a browser is the only
  # place they run — so this drives the method rather than mocking the fetch, and the case above it
  # proves the same method is what the real response reaches.
  def render_history(payload)
    page.execute_script(<<~JS, payload.deep_stringify_keys)
      const panel = document.querySelector(".history-panel")
      window.Stimulus.getControllerForElementAndIdentifier(panel, "history").render(arguments[0])
    JS
  end

  def entry(subject, oid: "a" * 40)
    { oid:, short_oid: oid[0, 8], subject:, author: "Seed", time: "2026-08-30T10:00:00Z", at_label: "2026-08-30 10:00" }
  end

  test "the panel lists this file's commits, views one, diffs it, and restores it" do
    root = make_repo_with_commits!(count: 8, touch_every: 4) # tracked.txt changed at c0 and c4
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    oids = history_oids(root, "tracked.txt")

    visit file_path(node.node_id)

    # NEWEST FIRST, AND ONLY THE COMMITS THAT TOUCHED THIS FILE — c1/c2/c3/c5/c6/c7 touched other
    # files and must not be here. The count is the assertion that the panel filtered by path at
    # all; a panel showing the repository's whole log would pass a "rows appeared" check.
    assert_selector ".history-row", count: 2
    assert_equal %w[c4 c0], all(".history-row .history-subject").map(&:text)
    # THE SERVER'S LABEL, NOT THE BROWSER'S (UX audit D1): each row's when is FilesController#history's
    # `at_label`, the absolute form every other timestamp in the app reads in, inside a <time> whose
    # datetime is the instant. toLocaleString() printed the browser's own form here ("11/1/2026,
    # 10:09:06 PM" in the audit), in the browser's zone.
    assert_selector ".history-row .history-meta time[datetime]", count: 2, text: /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}\z/
    # An exhausted walk with rows says nothing further — silence about older changes is TRUE here,
    # and this is the only condition under which it is.
    assert_no_selector ".history-note"

    older = find(".history-row[data-oid='#{oids.last}']")

    within(older) { click_on "View" }
    assert_selector ".history-blob", text: "v0"

    # THE DIFF IS BUILT IN THE BROWSER FROM TWO BLOBS, and `.cm-deletedChunk` is @codemirror/merge's
    # own decoration for the ORIGINAL side of a hunk — so it exists only if the merge extension
    # actually ran. `.cm-editor` alone would be satisfied by basicSetup with the extension dropped
    # on the floor, which is precisely CM6's silent failure mode for a duplicated @codemirror/state
    # (§14d). Here the original is c0's "v0" and the working tree is "v4".
    within(older) { click_on "Diff" }
    assert_selector ".history-diff .cm-editor", wait: 10
    assert_selector ".history-diff .cm-deletedChunk", wait: 10
    # NO MERGE CONTROLS, for diffview_controller's measured reason: rejectChunk dispatches a
    # document change that readOnly does not gate, so an enabled control would revert the BUFFER
    # and never the working tree (tinkerex#184, still open). If someone turns mergeControls on,
    # this line is what sends them to read why.
    assert_no_selector ".history-diff .cm-chunkButtons"

    # ASKED FIRST, IN WORDS THAT NAME WHAT IS LOST (UX audit B5). The restore writes over the working
    # copy and reloads the page, taking any unsaved editor text with it; the question says so, and
    # the date is the row's own, so the maker knows WHICH version they are bringing back.
    question = accept_confirm { within(older) { click_on "Restore" } }
    assert_match(/\ARestore the version from .+\? This replaces the current file and any unsaved edit\.\z/, question)

    # THE FLASH IS BOTH THE ASSERTION AND THE WAIT. It exists only on the reloaded page, so a query
    # for it matches NOTHING until the document swaps — which is what makes it safe to run across a
    # reload, unlike a selector both documents carry: Capybara checks visibility on every match, and
    # a match that goes stale mid-query raises an UNRETRYABLE "Node with given id does not belong to
    # the document" (observed here, on `.cm-content`). It also proves the redirect survived the
    # controller's `redirect: "manual"` fetch, which is the only reason that fetch is spelled that
    # way — a followed redirect would consume this notice inside the request nobody sees.
    assert_selector ".flash-notice", text: "Restored"

    # THE BYTES ON DISK, not the page's own idea of them — the working tree is what git will be
    # asked to commit.
    assert_equal "v0\n", File.read(File.join(library_root, "many", "tracked.txt"))

    # AND IT IS A PENDING EDIT, NOT A COMMIT (spec part 6): the commit box is where the maker
    # reviews it, which is what makes an accidental restore one click from undone.
    visit repo_commit_path(root.node_id)
    assert_selector "[data-path='tracked.txt']"
  end

  # NO IS NO: A DISMISSED RESTORE SENDS NOTHING. The question exists because the restore is not
  # free — it replaces the working copy and the page reload takes the editor's unsaved text — so
  # answering it No must leave the bytes, the commit box and the page exactly as they were. The
  # pending-edit count is the server's own witness that no POST arrived, since a restore that ran
  # records a Maker::RepoEdit even when nothing on screen changes.
  #
  # MUTATION-CHECKED (2026-11-02): with the `window.confirm` guard deleted from
  # history_controller.js#restore, `dismiss_confirm` finds no dialog and this goes RED
  # (Capybara::ModalNotFound); restored, green.
  test "a Restore answered No changes nothing" do
    root = make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    oids = history_oids(root, "tracked.txt")
    path = File.join(library_root, "many", "tracked.txt")
    before = File.read(path)

    visit file_path(node.node_id)
    older = find(".history-row[data-oid='#{oids.last}']")
    question = dismiss_confirm { within(older) { click_on "Restore" } }
    assert_includes question, "This replaces the current file and any unsaved edit."

    assert_no_selector ".flash-notice", text: "Restored"
    assert_selector ".history-row", count: 2 # the panel is still the panel, not a reloaded page
    assert_equal before, File.read(path)
    assert_equal 0, Maker::RepoEdit.where(user: @user).count, "a restore was recorded"
    assert_no_console_errors
  end

  # A RESTORE OVER AN UNSAVED EDIT ASKS ONCE, NOT TWICE. The editor guards an unsaved edit with the
  # browser's "Leave site?" prompt on a reload (editor_controller.js), and the restore reloads the
  # page — so without the `editor:discard` event history_controller.js sends after a yes, the maker
  # who just agreed to lose the edit would be asked again in the browser's words.
  #
  # THE PROMPT ITSELF CANNOT BE WATCHED: WebDriver accepts every beforeunload prompt on its own, so
  # a version of this test that waited for one passed with the event deleted (measured, 2026-11-02).
  # What is watched instead is the guard's own answer — a cancelable `beforeunload` dispatched in
  # the page is `defaultPrevented` exactly when the browser would ask — taken first while the edit
  # is unsaved (so the case can fail at all), then again from inside the discard event, recorded in
  # sessionStorage because the reload follows at once.
  #
  # MUTATION-CHECKED (2026-11-02): with the dispatch deleted from #restore, the recorded answer is
  # missing (nil, not "false") — RED; restored, green.
  test "a Restore over an unsaved edit stands the editor's leave-guard down" do
    root = make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    oids = history_oids(root, "tracked.txt")

    visit file_path(node.node_id)
    assert_selector ".cm-editor", wait: 10
    content = find(".cm-content")
    content.click
    content.send_keys(:end, " UNSAVED")
    assert page.evaluate_script(GUARD_HOLDS), "the unsaved edit is not guarded, so this case proves nothing"

    page.execute_script(<<~JS)
      sessionStorage.removeItem("guard-after-discard")
      document.addEventListener("editor:discard", () =>
        sessionStorage.setItem("guard-after-discard", String(#{GUARD_HOLDS})))
    JS
    older = find(".history-row[data-oid='#{oids.last}']")
    accept_confirm { within(older) { click_on "Restore" } }

    assert_selector ".flash-notice", text: "Restored"
    assert_equal "false", page.evaluate_script("sessionStorage.getItem('guard-after-discard')")
    assert_equal "v0\n", File.read(File.join(library_root, "many", "tracked.txt"))
    assert_no_console_errors
  end

  # THE CASE THE WHOLE PANEL EXISTS FOR. 260 commits, and other-1.txt was touched by exactly one of
  # them — 258 back, past the 250-commit default walk. The walk therefore finds NOTHING while the
  # file demonstrably has history, which is the state that must never render as "no history".
  test "a walk that stopped early says how far it looked, and Look further finds the change" do
    make_repo_with_commits!(count: 260, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "other-1.txt")

    visit file_path(node.node_id)

    assert_selector ".history-note", text: "No changes to this file in the last 250 commits"
    assert_no_selector ".history-row"
    # THE SENTENCE THAT WOULD BE A LIE. Only `stopped: "exhausted"` licenses it, and this walk
    # stopped at its cap — mutating the empty state to say this unconditionally is what this line
    # catches, and nothing else in the suite does.
    assert_no_text "No earlier history"

    # DOUBLING THE WALK REACHES IT: 500 commits covers all 260, so the server answers `exhausted`
    # and the row appears. That is also what proves the first assertion was about a CAP rather than
    # about an absent commit.
    click_on "Look further"
    assert_selector ".history-row", count: 1
    assert_selector ".history-subject", text: "c1"
    assert_no_selector ".history-note"

    assert_no_console_errors
  end

  # RESTORE IS HIDDEN, NOT DISABLED, WHERE THE SERVER SAYS THE FILE CANNOT BE RESTORED. Mutating
  # the check in `rowFor` to an unconditional append turns the second half of this red while the
  # first half stays green, which is what makes the pair worth having rather than one of them.
  test "Restore is offered only where the response says the file can be restored" do
    make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    visit file_path(node.node_id)
    assert_selector ".history-row", count: 2 # the real fetch landed before anything is replaced

    render_history({ stopped: "exhausted", walked: 8, restorable: true, entries: [ entry("c0") ] })
    assert_selector ".history-row button", text: "Restore"

    render_history({ stopped: "exhausted", walked: 8, restorable: false, entries: [ entry("c0") ] })
    # The ROW is still there — this is about one affordance being withheld, not about the panel
    # collapsing, and asserting only the absence would pass if rendering broke entirely.
    assert_selector ".history-row", count: 1
    assert_selector ".history-row button", text: "View"
    assert_no_selector ".history-row button", text: "Restore"
  end

  # ALL SIX CODES `FilesController` CAN REPORT, INCLUDING THE THREE ADDED FOR THE PANEL'S SAKE.
  # `stopped` is the endpoint's whole honesty, and this is where the panel's half of that is
  # pinned: exactly one of these six sentences may say the file has no history.
  test "every stopping condition gets a sentence, and only exhausted may say there is no history" do
    make_repo_with_commits!(count: 8, touch_every: 4)
    node = @user.nodes.present.find_by!(name: "tracked.txt")
    visit file_path(node.node_id)
    assert_selector ".history-row", count: 2

    render_history({ stopped: "exhausted", walked: 8, restorable: true, entries: [] })
    assert_selector ".history-note", text: "No earlier history for this file."

    render_history({ stopped: "walk_limit", walked: 250, restorable: true, entries: [] })
    assert_selector ".history-note", text: "No changes to this file in the last 250 commits."
    assert_no_text "No earlier history"

    # A FULL LIST IS NOT AN EMPTY ONE AND GETS NO "Look further": what stopped this walk was the
    # list filling up, so a deeper walk would return the same 25 rows.
    render_history({ stopped: "limit", walked: 40, restorable: true, entries: [ entry("c9") ] })
    assert_selector ".history-note", text: "Showing the 1 most recent changes to this file."
    assert_no_button "Look further"

    # THE THREE THAT NEVER WALKED AT ALL. Each carries the server's own sentence, and rendering an
    # empty list for any of them would read as "no history" — the same lie by omission.
    %w[no_repo no_worktree unavailable].each do |code|
      render_history({ stopped: code, walked: 0, restorable: false, reason: "Because #{code}.",
                       entries: [] })
      assert_selector ".history-note", text: "Because #{code}."
      assert_no_selector ".history-row"
      assert_no_text "No earlier history"
    end

    assert_no_console_errors
  end
end
