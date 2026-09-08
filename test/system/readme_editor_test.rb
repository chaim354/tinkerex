require "application_system_test_case"
require "support/git_repo_fixture"

# The project page's README editor, in a real browser — the only tier that can see it work
# (stage 4, S4-4; the plan's amendment 1).
#
# WHY THIS FILE HAS TO EXIST, on repo_editor_test.rb's argument. The Ruby suite drives
# `PATCH /projects/:id/readme` directly (test/integration/web/readme_edit_test.rb) by POSTING
# `content` itself, so the door is pinned — what no request test can say is whether the page's
# Save ever posts what the maker TYPED. readme_controller.js#sync is the one line that carries
# it: the form's real field is a textarea CodeMirror hides, and without the copy-back the form
# submits whatever that textarea held when the editor mounted — the ORIGINAL bytes — with
# "README saved." and a redirect to prove it worked. That is this repo's dominant failure shape
# (CLAUDE.md §15), and this file is the one place it goes red: empty `sync()`'s body and the
# marker assertions below fail while every request test stays green.
#
# SHARE BACKEND, ASSIGNED DIRECTLY, for repo_editor_test.rb's reason: the editor must write REAL
# BYTES back through the port, and a tmpdir plus one scan is the cheapest way there.
class ReadmeEditorTest < ApplicationSystemTestCase
  include GitRepoFixture

  BODY = "# Lamp\n\nWalnut.\n".freeze
  MARKER = "MARKER-7c1".freeze

  setup do
    @library = use_fresh_share_library!
    @user = sign_in_as("readme-editor@example.com")
    @project = @user.maker_projects.create!(name: "Desk Lamp")
    @project.ensure_library_folder!(@user)
    @path = File.join(library_root, "Projects", @project.slug, "README.md")
    File.write(@path, BODY)
    Library::ScanJob.new.perform(user_id: @user.id)
  end

  test "the README editor mounts on the project page, saves what was typed, and the card shows it" do
    visit project_path(@project)
    assert_selector ".readme-card .markdown h1", text: "Lamp"

    # THE EDITOR IS LAZY: nothing is fetched and nothing mounts until the details opens.
    assert_no_selector ".readme-editor .cm-editor"
    # `/edit readme/i` because Selenium reports RENDERED text (repo_browser_test.rb records why).
    find(".readme-editor summary", text: /edit readme/i).click
    assert_selector ".readme-editor .cm-editor", wait: 10

    # THE TRADE IS NAMED ON THE EDITOR ITSELF, and only visible once it is open — a closed
    # <details> hides its contents from Selenium as it does from the maker. Share keeps no history.
    assert_selector ".readme-editor .no-history-note", text: /keeps no history for this file/

    # Types at the end of whichever line the click landed on and saves — the marker's POSITION is
    # not the subject; that it reaches the page and the disk is.
    content = find(".readme-editor .cm-content")
    content.click
    content.send_keys(:end, " #{MARKER}")
    click_on "Save README"

    # THE REDIRECTED PAGE, NOT THE BUFFER: the card is rebuilt from the bytes the port reads back.
    assert_selector ".flash-notice", text: "README saved."
    assert_selector ".readme-card .markdown", text: MARKER
    # THE BYTES ON DISK, not the page's own idea of them.
    assert_includes File.read(@path), MARKER

    assert_no_console_errors
  end
end
