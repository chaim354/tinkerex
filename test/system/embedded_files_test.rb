require "application_system_test_case"

# EMBEDDED FILES, DRIVEN (2026-11-19; docs/superpowers/specs/2026-11-19-embedded-files-design.md).
# The request suites (sandbox_test.rb, file_embed_test.rb) prove what the server sends; only a browser
# proves what the sandbox DOES — that a page in the frame runs its scripts and loads the file beside
# it, and cannot reach the page around it or this app's cookies. The probe page reports what it was
# allowed into its own DOM, and the test reads it from inside the frame.
#
# REAL FILES ON A SHARE ROOT OF ITS OWN, indexed by the scanner, so every byte comes through the port.
class EmbeddedFilesTest < ApplicationSystemTestCase
  include WebHelpers

  PROBE = <<~HTML.freeze
    <!doctype html><title>probe</title>
    <p id="out">pending</p>
    <script src="probe.js"></script>
    <script>
      const seen = []
      try { seen.push("parent:" + parent.document.title) } catch (e) { seen.push("parent:blocked") }
      try { seen.push("cookie:" + document.cookie) } catch (e) { seen.push("cookie:blocked") }
      seen.push("origin:" + self.origin)
      seen.push("sibling:" + (window.probeLoaded ? "loaded" : "missing"))
      document.getElementById("out").textContent = seen.join(" ")
    </script>
  HTML

  # Chrome reports a blocked cross-origin frame access as a console message even when the page
  # catches it, and that refusal is the very thing this suite asserts.
  BLOCKED_FRAME = /Blocked a frame with origin/

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("embedded-files@example.com")
    @project = @user.maker_projects.create!(name: "PC Case")
    folder = @root.join("Projects", @project.slug)
    folder.join("viewer").mkpath
    folder.join("viewer", "probe.html").write(PROBE)
    folder.join("viewer", "probe.js").write("window.probeLoaded = true\n")
    folder.join("notes.md").write("# Build notes\n\nCut the walnut first.\n")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @project.update!(folder_node_id: @user.nodes.find_by!(storage_path: "Projects/#{@project.slug}").node_id)
    @html = @user.nodes.find_by!(storage_path: "Projects/#{@project.slug}/viewer/probe.html")
    @notes = @user.nodes.find_by!(storage_path: "Projects/#{@project.slug}/notes.md")
  end

  def probe_report
    within_frame(find("iframe.preview-html")) do
      assert_no_selector "#out", text: "pending", wait: 10
      find("#out").text
    end
  end

  # MUTATION-CHECKED (2026-11-19): with `allow-same-origin` added to Maker::HtmlSandbox::PERMISSIONS
  # (attribute and header alike) the probe reads the parent page's title instead of being refused,
  # and this test goes red.
  test "an HTML file runs in an opaque origin: its own scripts and siblings load, the page around it is out of reach" do
    visit file_path(@html.node_id)
    report = probe_report

    assert_includes report, "parent:blocked"
    assert_includes report, "cookie:blocked"
    assert_includes report, "origin:null"
    assert_includes report, "sibling:loaded"
    assert_no_console_errors(ignoring: [ BLOCKED_FRAME ])
  end

  test "File blocks on the project page: the HTML file running, a note's preview area beside it" do
    @project.blocks.create!(user: @user, kind: "file", node_id: @html.node_id)
    @project.blocks.create!(user: @user, kind: "file", node_id: @notes.node_id)

    visit project_path(@project)
    assert_includes probe_report, "sibling:loaded"

    within_frame(find("iframe.embed-frame-view")) do
      assert_selector ".markdown-rendered h1", text: "Build notes"
      assert_no_selector ".rail"
    end
    assert_no_console_errors(ignoring: [ BLOCKED_FRAME ])
  end
end
