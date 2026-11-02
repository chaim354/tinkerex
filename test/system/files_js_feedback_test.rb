require "application_system_test_case"
require "zip"

# WHAT THE LIBRARY'S UPLOAD AND RESCAN SAY WHILE THEY WORK AND WHEN THEY FAIL (UX audit B8). Each
# of these is a line a Stimulus controller writes after the page rendered, so a request test sees an
# empty span and nothing else: the share/s3 form's "Uploading…" exists only between the file
# picker closing and the next page arriving, a failure is an alert built in the page, and the
# rescan's "Still scanning…" replaces nothing the server sent.
#
# SHARE, INSTALLED HERE (use_fresh_share_library!), for test/system/README.md's reason: the subject
# is the controllers' wording, not which backend holds the bytes. The chunk flow's half of the
# failure sentence (uploader_controller.js) runs only where a sync server is configured, which is
# why the shared wording lives in lib/chunk_upload.js and is driven here through the zip path both
# flows share.
#
# FIXTURES ARE BUILT IN A Dir.mktmpdir, never under the repo: Selenium cannot read a file under
# ~/Desktop (macOS TCC; test/system/README.md).
class FilesJsFeedbackTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("feedback-#{SecureRandom.hex(4)}@example.com")
    @cad = FileLayer.current.mkdir(@user, parent_node_id: nil, name: "cad")
    @dir = Dir.mktmpdir("files_js_feedback")
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
    FileLayer.reset!
  end

  # THE FORM PATH SAYS IT IS WORKING. Its POST is a plain browser navigation (`turbo: false`), so the
  # page sits unchanged until the server answers; the line is all a maker sees meanwhile, and the
  # live region is what a screen reader hears. `requestSubmit` is held for the assertion — the real
  # upload is topbar_upload_test.rb's, and the line is gone the moment the next page lands.
  #
  # MUTATION-CHECKED (2026-11-02): with zip_upload_controller.js#submit's setStatus line removed, the
  # status assertion goes RED (the span is empty); restored, green.
  test "the share upload form says Uploading NAME while it submits, in a live region" do
    path = File.join(@dir, "notes.txt")
    File.write(path, "hello")
    visit files_path(folder: @cad.node_id)
    page.execute_script("HTMLFormElement.prototype.requestSubmit = function () { window.__heldSubmit = this.action }")

    attach_file("topbar_upload_file", path, make_visible: true)

    status = find(".topbar-upload .upload-status", text: "Uploading notes.txt…")
    assert_equal "polite", status[:"aria-live"]
    assert_match %r{/files\z}, page.evaluate_script("window.__heldSubmit")
    assert_no_console_errors
  end

  # A FAILED FILE IS AN ALERT IN WORDS, AND THE RUN STAYS ON SCREEN. A model zip unpacks and a second
  # file in the same selection meets a name already taken in the folder: the alert names the file
  # and why — never the port's `"cad/dup.txt" already exists` — the status line says what did land,
  # and the page does not navigate, because a reload would wipe the one line that says what failed.
  #
  # MUTATION-CHECKED (2026-11-02): with reportAndLand's `alertToast(failure)` replaced by `false`
  # (lib/zip_unpack.js), the alert assertion goes RED; restored, green.
  test "a refused file in an upload is named in an alert and the page stays" do
    FileLayer.current.write(@user, parent_node_id: @cad.node_id, name: "dup.txt", io: StringIO.new("already here"))
    dup = File.join(@dir, "dup.txt")
    File.write(dup, "a second copy")
    zip = File.join(@dir, "kit.zip")
    Zip::File.open(zip, create: true) { |z| z.get_output_stream("kit/part.stl") { |io| io.write("solid p\nendsolid\n") } }
    visit files_path(folder: @cad.node_id)

    attach_file("topbar_upload_file", [ zip, dup ], make_visible: true)

    alert = find(".flash-stack .flash.flash-alert[role='alert']", wait: 30)
    assert_equal "This one was not uploaded: dup.txt (the folder already has a file with that name).",
                 alert.find(".flash-text").text
    assert_no_text "already exists"
    assert_selector ".topbar-upload .upload-status", text: "Unpacked kit.zip. Reload to see them."
    assert_current_path files_path(folder: @cad.node_id)
    assert_equal "already here", File.read(@root.join("cad", "dup.txt"))
    assert_no_console_errors(ignoring: [ /status of 422/, /already exists/ ])
  end

  # THE RESCAN SAYS IT IS STILL GOING, THEN WHAT IT KNOWS. The element was empty for the whole
  # minute it polls, so once the 6-second notice timed out nothing on the page said a scan was
  # running. At the deadline it says the truthful "Nothing yet" (the scan may still be walking, or
  # may have refused — the page cannot tell). The deadline is brought forward through the
  # controller rather than waited for.
  #
  # MUTATION-CHECKED (2026-11-02): with connect()'s `textContent = WAITING` removed from
  # scanreload_controller.js, the first assertion goes RED (the element is empty); restored, green.
  test "a rescan in progress says Still scanning, then Nothing yet at the deadline" do
    visit files_path(scanning: 1)

    waiting = find("[data-controller~='scanreload']", text: "Still scanning…")
    assert_equal "polite", waiting[:"aria-live"]

    page.execute_script(<<~JS)
      const el = document.querySelector("[data-controller~='scanreload']")
      window.Stimulus.getControllerForElementAndIdentifier(el, "scanreload").deadline = 0
    JS
    assert_selector "[data-controller~='scanreload']", text: "Nothing yet — reload to check again.", wait: 10
    assert_current_path files_path(scanning: 1)
    assert_no_console_errors
  end
end
