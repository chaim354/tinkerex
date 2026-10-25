require "application_system_test_case"

# The Measure view on a MULTI-PAGE file (LightBurn 2.2, MillMage 0.9): one page on the stage, a
# picker to change it, and everything — the readout, Print, the exports — acting on that page.
#
# BROWSER-TIER for lbrn_measure_test.rb's reason: the picker, the filtering and the redraw all live
# in measure_controller.js, and the payload keys they read are pinned server-side by
# test/services/maker/previews/lbrn_pages_test.rb. Same share-backend setup as that file, and the
# same load-bearing FileLayer.reset! in teardown.
#
# `pages.lbrn2` (see its header) is saved on page 2, "Back" — one circle r 25 at x 375..425 — while
# page 1 holds a Rect and a second circle at x 70..275 and page 3 is empty.
class MeasurePagesTest < ApplicationSystemTestCase
  PAGES = "pages.lbrn2".freeze
  ONE_PAGE = "sample.lbrn2".freeze
  SAVED_EMPTY = "saved-on-empty.lbrn2".freeze

  setup do
    @root = Pathname.new(Dir.mktmpdir("measure-pages"))
    # Before the first page render: an EMPTY share root reads as an unmounted mount point.
    [ PAGES, ONE_PAGE ].each do |f|
      File.binwrite(@root.join(f), File.binread(Rails.root.join("test/fixtures/files", f)))
    end
    # The same file saved while its EMPTY third page was open — what LightBurn writes when you add
    # a page and save straight away.
    File.binwrite(@root.join(SAVED_EMPTY),
                  File.binread(Rails.root.join("test/fixtures/files", PAGES)).sub('CurrentPage="1"', 'CurrentPage="2"'))
    FileLayer.current = FileLayer::Share.new(root: @root.to_s)

    @user = sign_in_as("measure-pages@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @pages_id = @user.nodes.find_by!(storage_path: PAGES).node_id
    @one_id   = @user.nodes.find_by!(storage_path: ONE_PAGE).node_id
    @empty_id = @user.nodes.find_by!(storage_path: SAVED_EMPTY).node_id
    render_geometry!(@pages_id, PAGES)
    render_geometry!(@one_id, ONE_PAGE)
    render_geometry!(@empty_id, SAVED_EMPTY)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # THE BUG THIS FIXES: every page drawn on one stage, stacked. The saved page alone is one
  # contour; stacked, the stage held three. The viewBox is page 2's own box (x 375, padded by 2% of
  # 50) — framed on the union of every page it would start at x 62.9.
  test "a multi-page file opens on the page it was saved on, alone and framed on it" do
    open_measure_view(@pages_id)

    assert_selector ".measure-stage .measure-contour", count: 1
    assert_equal "374 -226 52 52", find(".measure-stage svg")[:viewBox]
    assert_selector ".measure-dims", text: "1 shapes on this page"

    picker = find("select.measure-page")
    assert_equal "1", picker.value
    assert_equal [ "Page 1", "Back", "Page 3 (empty)" ], picker.all("option").map(&:text)
    assert picker.find("option", text: "Page 3 (empty)").disabled?, "an empty page is listed but not offered"

    find(".measure-stage .measure-contour").click
    assert_selector ".measure-dims", text: "⌀50 mm"
  end

  # A NEW PAGE IS A NEW DRAWING: the part marked on page 2 is not on page 1's stage, so the
  # selection must not follow it, or Print would promise a part the view no longer shows.
  test "choosing another page draws that page and drops the selection" do
    open_measure_view(@pages_id)
    find(".measure-stage .measure-contour").click
    assert_selector "[data-measure-target='printButton']", text: "Print 1 part"

    find("select.measure-page").select("Page 1")

    assert_selector ".measure-stage .measure-contour", count: 2
    assert_no_selector ".measure-contour--marked"
    assert_selector "[data-measure-target='printButton']", text: "Print all"
    assert_selector ".measure-dims", text: "2 shapes on this page"
    assert_selector ".measure-view--ready"
  end

  # Two pages saved as SVG must not collide on one name — the second would refuse as "already
  # taken". The page's NUMBER goes in the name, never its text.
  test "an export from a page is named for that page" do
    open_measure_view(@pages_id)
    page.execute_script(<<~JS)
      window.__downloads = []
      HTMLAnchorElement.prototype.click = function () { window.__downloads.push(this.download) }
    JS

    find("[data-measure-target='svgButton']").click

    assert_equal [ "pages-page2-parts.svg" ], page.evaluate_script("window.__downloads")
  end

  # An empty stage has no bar, so no picker to leave by: a file saved on its empty page opens on the
  # first page with something to measure instead.
  test "a file saved on an empty page opens on the first page with shapes" do
    open_measure_view(@empty_id)

    assert_equal "0", find("select.measure-page").value
    assert_selector ".measure-stage .measure-contour", count: 2
  end

  test "a one-page file shows no page picker and reads as it always did" do
    open_measure_view(@one_id)

    assert_selector "select.measure-page", visible: :hidden
    assert_no_selector "select.measure-page", visible: true
    assert_no_selector ".measure-dims", text: "on this page"
  end

  private
    def render_geometry!(node_id, filename)
      token = FileLayer.current.stat(@user, node_id: node_id).content_token
      preview = Maker::Previews::Enqueue.call(user: @user, node_id: node_id, name: filename,
                                              version_id: token, kind: "geometry")
      Maker::GeneratePreviewJob.perform_now(preview.id, filename: filename)
      assert_equal "ready", preview.reload.status, "the geometry payload must be ready to measure"
    end

    def open_measure_view(node_id)
      visit file_path(node_id)
      click_on "Measure"
      # --ready reveals the stage; without waiting for it the assertions race the fetch.
      assert_selector ".measure-view--ready"
    end
end
