require "application_system_test_case"

# What only a browser can show about PR 2's Files pages: the overflow menu opens and closes the
# way a menu should, and the notes composer — Lexxy inside a <details> that starts closed —
# actually takes a note. The second is the risk the spec (§13) named; this is the verification.
#
# MUTATION-CHECKED, each assertion separately (this directory's README requires it, and §15 asks
# that each assertion be shown to carry weight rather than the test merely going red somewhere):
#   - Commenting out BOTH `document.addEventListener` lines in menu_controller.js#connect reddens
#     test 1 at the assertion AFTER THE OUTSIDE CLICK: `expected not to find visible css
#     ".page-actions details.menu[open]", found 1 match: "⋯\nRescan library"`. The Escape
#     assertion below it is never reached, so that mutation alone does not speak for it.
#   - Commenting out only the `keydown` listener reddens the same test at the assertion AFTER
#     ESCAPE, with the identical message — the outside-click half having passed first. So both
#     halves of the controller are pinned, not just whichever fails first.
#   - Rendering the composer open (`<details class="composer" open>` in files/show.html.erb)
#     reddens test 2 at its closed-before-the-click assertion: `expected not to find visible css
#     ".notes-panel details.composer[open]", found 1 match: "Add a note"`.
#
# LEXXY'S EDITABLE SURFACE IS `[contenteditable='true']` INSIDE `lexxy-editor`, and it lays itself
# out fine inside a details that started closed — the spec's named risk did not materialise. The
# note reaches `article.note .note-body`, so this is a claim about the note landing, not about the
# element being present.
class FilesPagesTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("files-pages@example.com")
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "the overflow menu opens on its button and closes on an outside click or Escape" do
    visit files_path
    assert_selector ".page-actions details.menu"
    assert_no_selector ".page-actions details.menu[open]"
    find(".page-actions details.menu > summary").click
    assert_selector ".page-actions details.menu[open] .menu-item", text: /rescan/i
    find("h1", text: "Files").click
    assert_no_selector ".page-actions details.menu[open]"
    find(".page-actions details.menu > summary").click
    assert_selector ".page-actions details.menu[open]"
    find("body").send_keys(:escape)
    assert_no_selector ".page-actions details.menu[open]"
    assert_no_console_errors
  end

  test "a note written through the closed composer lands on the page" do
    node = create_node!(@user, node_id: SecureRandom.uuid, name: "bracket.dxf", kind: "file")
    visit file_path(node.node_id)
    assert_selector ".notes-panel details.composer"
    assert_no_selector ".notes-panel details.composer[open]"
    find(".notes-panel details.composer > summary", text: "Add a note").click
    assert_selector ".notes-panel details.composer[open] lexxy-editor", visible: true
    find(".notes-panel lexxy-editor [contenteditable='true']").click
    find(".notes-panel lexxy-editor [contenteditable='true']").send_keys("Print upside down, 4 walls.")
    click_on "Add note"
    assert_selector ".notes-panel article.note .note-body", text: "Print upside down, 4 walls."
    assert_no_console_errors
  end

  # THE COPY BUTTON, DRIVEN. Only a browser can say whether a Stimulus identifier resolved, whether
  # the click reached `copy#copy`, and whether the label flashed and came back — §14d's silent
  # no-op is exactly the failure a request test cannot see.
  #
  # `navigator.clipboard.writeText` IS STUBBED RATHER THAN READ BACK. Reading the real clipboard
  # needs a permission this driver does not grant, and the assertion that matters is what the
  # controller passed — the same shimming idiom measure_export_test.rb uses for
  # URL.createObjectURL.
  #
  # `exact_text:`, NOT `text:`, ON BOTH LABELS. Capybara's `text:` is a SUBSTRING match and
  # "Copied" contains "Copy", so the restore assertion below would be satisfied by the flashed
  # label it exists to prove has gone — a test that could not fail for its own reason.
  test "the path's Copy button copies the path and says it did" do
    node = @user.nodes.create!(node_id: "n-copy", name: "lid.svg", kind: "file",
                               mtime: 1_000_000_000, size: 4,
                               content_hash: "h-copy", current_version_id: "v-copy")
    visit file_path(node.node_id)
    assert_selector ".meta .file-path-value", text: "lid.svg"

    page.execute_script(<<~JS)
      window.__copied = null
      Object.defineProperty(navigator, "clipboard", {
        configurable: true,
        value: { writeText: (t) => { window.__copied = t; return Promise.resolve() } }
      })
    JS

    find(".meta .file-path button", text: "Copy").click

    assert_equal "lid.svg", page.evaluate_script("window.__copied")
    assert_selector ".meta .file-path button", exact_text: "Copied"
    assert_selector ".meta .file-path button", exact_text: "Copy", wait: 5
    assert_no_console_errors
  end

  # THE INSECURE-CONTEXT PATH, WHICH IS THE ORDINARY ONE ON A SELF-HOSTED PLAIN-HTTP BOX. With
  # `navigator.clipboard` shadowed away the controller must reach execCommand rather than doing
  # nothing — and doing nothing is exactly what an unguarded `navigator.clipboard.writeText` would
  # do there, silently. (The driver serves 127.0.0.1, which Chrome treats as a SECURE context, so
  # shadowing the API is the only way to reach this branch from here at all.)
  test "with no clipboard API the copy falls back to execCommand" do
    node = @user.nodes.create!(node_id: "n-copy2", name: "tray.svg", kind: "file",
                               mtime: 1_000_000_000, size: 4,
                               content_hash: "h-copy2", current_version_id: "v-copy2")
    visit file_path(node.node_id)

    page.execute_script(<<~JS)
      window.__exec = null
      Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined })
      document.execCommand = (cmd) => { window.__exec = cmd; return true }
    JS

    find(".meta .file-path button", text: "Copy").click

    assert_equal "copy", page.evaluate_script("window.__exec")
    assert_selector ".meta .file-path button", exact_text: "Copied"
    assert_no_console_errors
  end

  # THE PAGE FINISHES ITS OWN PREVIEW (story 2.11). Nobody drives this reload: the poll asks
  # /files/thumbnails, the row goes ready underneath it, and the page comes back carrying the
  # picture. The row is made ready IN RUBY because ActiveJob's test adapter never runs what it
  # queues, and a system test shares its connection with the server thread.
  #
  # THE PENDING ROW IS THE PAGE'S OWN DOING, not a fixture: FilesController#current_thumbnail
  # enqueues when nothing current exists, so the first render creates it. `port_upload` is an
  # INTEGRATION helper (it POSTs through a Rack session) and ActionDispatch::SystemTestCase
  # descends from ActiveSupport::TestCase, not from IntegrationTest — there is no `post` here, and
  # the browser holds the only signed-in session. Both content columns for §14a's reason: on share
  # `FileLayer::Share#stat` answers from the ROW, so `content_hash` IS the content token here.
  test "a page opened mid-render reloads itself when the preview lands" do
    node = @user.nodes.create!(node_id: "n-pending", name: "widget.3mf", kind: "file",
                               mtime: 1_000_000_000, size: 4,
                               content_hash: "h-pending", current_version_id: "v-pending")
    visit file_path(node.node_id)
    assert_selector "[data-thumbs-target='cell'][data-thumbs-pending='true']", visible: :all
    assert_no_selector "img.preview-image"

    token = FileLayer.current.stat(@user, node_id: node.node_id).content_token
    preview = @user.maker_previews.find_by!(node_id: node.node_id, version_id: token,
                                            kind: "thumbnail")
    preview.asset.attach(io: StringIO.new("\x89PNG\r\n\x1A\n".b), filename: "t.png",
                         content_type: "image/png")
    preview.update!(status: "ready")

    assert_selector "img.preview-image", wait: 15
    assert_no_selector "[data-thumbs-target='cell']", visible: :all
    assert_no_console_errors
  end
end
