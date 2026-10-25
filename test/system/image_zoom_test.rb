require "application_system_test_case"
require "zlib"

# A FILE PAGE'S PICTURE OPENS BIG AND ZOOMABLE (files/viewers/_zoomable, image_zoom_controller.js).
#
# BROWSER-TIER BY CONSTRUCTION (test/system/README.md): a <dialog> in the top layer, an SVG stage the
# controller builds from the poster it was clicked on, and a viewBox lib/svg_pan_zoom moves. None of
# it is observable from a request test. The wheel and the drag here are REAL input, through
# Selenium's actions, not synthetic events: what this page adds over the board's and Measure's
# stages is that the overlay must receive them at all (and keep the wheel off the page behind it).
#
# SHARE BACKEND, INSTALLED BY THE TEST (use_fresh_share_library!): the plain image's bytes have to
# come back out of the byte route, and the README's "do not re-run the backend matrix through the
# browser" applies — this is not a backend test.
#
# MUTATION-CHECKED (§15; outputs in the PR): dropping the `click` action from the partial reddens the
# photo, Turbo-cache and visitor tests (the poster test opens with Enter); removing `touch-action:
# none` from `.image-zoom-stage svg`, or the card's `mix-blend-mode`, reddens the poster test;
# deleting the `dialog.close()` from connect() reddens the Turbo-cache test; dropping the decode()
# check reddens the broken-picture test.
class ImageZoomTest < ApplicationSystemTestCase
  setup do
    @root = use_fresh_share_library!
    # Files land BEFORE the first page render: Share reads an empty root as an unmounted mount.
    File.binwrite(@root.join("photo.png"), File.binread(Rails.root.join("test/fixtures/files/sample.png")))
    # AN SVG WITH ONLY A viewBox, whose natural size a browser does not know, so the overlay has to
    # take the picture's shape from the poster's laid-out box. PORTRAIT, so a box read off a
    # browser's 300 x 150 default would be the wrong shape rather than a coincidentally right one.
    File.write(@root.join("outline.svg"), <<~SVG)
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 160"><rect x="10" y="10" width="80" height="140" fill="none" stroke="black" stroke-width="2"/></svg>
    SVG
    %w[plate.dxf scan.tif bracket.stl].each { |name| File.binwrite(@root.join(name), "x") }
    File.binwrite(@root.join("broken.png"), "not a png")
    @user = sign_in_as("image-zoom@example.com")
    Library::Scanner.call(@user, root: @root.to_s, max_delete_pct: 100)
    @nodes = @user.nodes.where(kind: "file").index_by(&:name)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  test "a photo opens over the whole window, and the wheel, a drag, the buttons and Reset move it" do
    visit file_path(@nodes.fetch("photo.png").node_id)
    poster = find(".image-zoom-frame img.preview-image.zoomable")
    wait_until(message: "the photo never loaded") { page.evaluate_script("arguments[0].naturalWidth", poster).to_i.positive? }
    assert_no_selector "dialog.image-zoom[open]"

    poster.click

    assert_selector "dialog.image-zoom[open]"
    assert_equal poster[:src], page.evaluate_script("document.querySelector('.image-zoom-stage image').href.baseVal"),
                 "the overlay must show the poster's own picture"
    fills = page.evaluate_script(<<~JS)
      (() => { const r = document.querySelector("dialog.image-zoom").getBoundingClientRect();
               return [r.left, r.top, r.width - document.documentElement.clientWidth, r.height - window.innerHeight] })()
    JS
    fills.each { |gap| assert_in_delta 0, gap, 1, "the overlay must fill the window (#{fills.inspect})" }
    home = view_box
    assert_equal [ 0.0, 0.0 ], home.first(2)

    stage = find(".image-zoom-stage svg")
    browser.action.scroll_from(Selenium::WebDriver::WheelActions::ScrollOrigin.element(stage.native), 0, -300).perform
    wait_until(message: "a wheel up never zoomed in") { view_box[2] < home[2] }

    zoomed = view_box
    browser.action.move_to(stage.native).click_and_hold.move_by(80, 0).release.perform
    wait_until(message: "a drag never panned") { view_box[0] < zoomed[0] }
    assert_in_delta zoomed[1], view_box[1], 0.01, "a horizontal drag must not move the view vertically"

    click_on "Reset"
    assert_equal home, view_box, "Reset must return the view the overlay opened with"
    find("button[aria-label='Zoom in']").click
    assert_operator view_box[2], :<, home[2], "+ must zoom in"
    find("button[aria-label='Zoom out']").click
    find("button[aria-label='Zoom out']").click
    assert_operator view_box[2], :>, home[2], "− must zoom out"

    find("dialog.image-zoom").send_keys(:escape)
    assert_no_selector "dialog.image-zoom[open]"
    # The dialog's `close` event is a task queued after `open` drops, so both of these are waits.
    wait_until(message: "closing must empty the stage") do
      page.evaluate_script("document.querySelector('.image-zoom-stage').childElementCount").zero?
    end
    wait_until(message: "focus must go back to the picture") do
      page.evaluate_script("document.activeElement === document.querySelector('img.zoomable')")
    end
    assert_no_console_errors
  end

  # EVERY OTHER RESTING PICTURE: the Measure poster (a render, and an SVG that is its own poster),
  # the thumbnail tail, and the 3D viewer's poster. A render opens on the card's ground and blend.
  test "every poster opens from the keyboard on the card's ground, and Close shuts it" do
    %w[plate.dxf scan.tif bracket.stl].each { |name| ready_thumbnail!(@nodes.fetch(name)) }

    { "plate.dxf" => ".measure-fallback", "outline.svg" => ".measure-fallback",
      "scan.tif" => ".preview", "bracket.stl" => ".model-viewer-fallback" }.each do |name, container|
      visit file_path(@nodes.fetch(name).node_id)
      poster = find("#{container} .render-card img.preview-image.zoomable")
      wait_until(message: "#{name}'s poster never loaded") { page.evaluate_script("arguments[0].complete", poster) }
      shape = page.evaluate_script("(() => { const r = arguments[0].getBoundingClientRect(); return r.width / r.height })()", poster)

      poster.send_keys(:enter)

      assert_selector "dialog.image-zoom[open] .image-zoom-stage.image-zoom-stage--card svg image", visible: :all
      style = page.evaluate_script(<<~JS)
        (() => { const svg = document.querySelector(".image-zoom-stage svg");
                 return [getComputedStyle(svg).touchAction, getComputedStyle(svg.querySelector("image")).mixBlendMode] })()
      JS
      assert_equal [ "none", "multiply" ], style, "#{name}: the stage must take a pinch and multiply the render onto the card"
      w, h = view_box.last(2)
      assert_in_delta shape, w / h, 0.02, "#{name}: the overlay must keep the poster's shape"

      click_on "✕ Close"
      assert_no_selector "dialog.image-zoom[open]"
    end
    assert_no_console_errors
  end

  # A PICTURE THAT NEVER LOADED HAS NOTHING TO ENLARGE, so the click is ignored rather than opening an
  # empty window. Its natural size is 0 x 0, but by the spec so is an SVG's with only a viewBox, which
  # is why the controller asks decode() and not the size (outline.svg above opens).
  test "a picture that never loaded does not open" do
    visit file_path(@nodes.fetch("broken.png").node_id)
    poster = find("img.zoomable")
    wait_until(message: "the broken picture never finished failing") { page.evaluate_script("arguments[0].complete", poster) }

    poster.click

    assert_no_selector "dialog.image-zoom[open]", wait: 1
  end

  # LEAVING WITH THE OVERLAY OPEN (a phone's back gesture) caches the page with its dialog open, and
  # coming back restores that clone under a fresh controller. Connect must shut it, or it sits open
  # inline in the card with nothing driving it.
  test "a page restored from Turbo's cache comes back with the overlay shut" do
    here = file_path(@nodes.fetch("photo.png").node_id)
    visit here
    find("img.zoomable").click
    assert_selector "dialog.image-zoom[open]"
    # The page behind a modal dialog is inert, so no link can be clicked: a script's visit stands in
    # for the gesture. Either way Turbo caches the page as it leaves it, with the dialog open.
    page.execute_script("document.body.dataset.snapshotProbe = 'cached'")
    page.execute_script("Turbo.visit(#{trash_index_path.to_json})")
    assert_current_path trash_index_path

    page.go_back
    assert_current_path here
    wait_until(message: "Back re-rendered the page instead of restoring Turbo's snapshot of it") do
      page.evaluate_script("document.body.dataset.snapshotProbe") == "cached"
    end

    assert_no_selector "dialog.image-zoom[open]", visible: :all
    assert_equal 0, page.evaluate_script("document.querySelector('.image-zoom-stage').childElementCount")
    find("img.zoomable").click
    assert_selector "dialog.image-zoom[open] .image-zoom-stage svg"
    assert_no_console_errors
  end

  # A VISITOR'S FILE PAGE RENDERS THE SAME PARTIALS (public/files/view.html.erb), so the picture
  # opens for someone with no session too — the overlay fetches nothing and names no URL of its own.
  test "a visitor's public file page opens its picture the same way" do
    @user.update!(handle: "zoomer")
    project = @user.maker_projects.create!(name: "Lamp", visibility: "public")
    folder = project_folder_rows!(@user, project)
    @user.nodes.find_by!(node_id: folder.parent_node_id).update!(storage_path: Maker::ProjectFolders::ROOT)
    folder.update!(storage_path: File.join(Maker::ProjectFolders::ROOT, project.slug))
    @root.join(folder.storage_path).mkpath
    body = File.binread(Rails.root.join("test/fixtures/files/sample.png"))
    photo = create_node!(@user, node_id: SecureRandom.uuid, name: "lamp.png", kind: "file",
                                parent_node_id: folder.node_id, mtime: 1, size: body.bytesize,
                                content_hash: "h-lamp")
    @root.join(photo.storage_path).binwrite(body)

    Capybara.reset_sessions!
    visit public_file_view_path("zoomer", project.slug, photo.node_id)
    find("img.zoomable").click

    assert_selector "dialog.image-zoom[open] .image-zoom-stage svg image", visible: :all
    stage = find(".image-zoom-stage svg")
    home = view_box
    browser.action.scroll_from(Selenium::WebDriver::WheelActions::ScrollOrigin.element(stage.native), 0, -300).perform
    wait_until(message: "a wheel up never zoomed in on the visitor's page") { view_box[2] < home[2] }
    find("dialog.image-zoom").send_keys(:escape)
    assert_no_selector "dialog.image-zoom[open]"
    assert_no_console_errors
  end

  private

  def browser = page.driver.browser

  def view_box
    page.evaluate_script("document.querySelector('.image-zoom-stage svg').getAttribute('viewBox')")
        .to_s.strip.split(/[\s,]+/).map(&:to_f)
  end

  # A READY, CURRENT THUMBNAIL (files_layout_test.rb's helper, for its reason: public_fixture.rb's
  # module defines a `sign_in_as` of its own), 160 x 90 so the poster has a shape to keep.
  def ready_thumbnail!(node)
    # find_or_initialize: the scan may already have queued this node's one row (one per node and kind).
    preview = @user.maker_previews.find_or_initialize_by(node_id: node.node_id, kind: "thumbnail")
    preview.update!(status: "ready",
                    version_id: FileLayer.current.stat(@user, node_id: node.node_id).content_token,
                    renderer_revision: Maker::Previews::Enqueue.revision_for_name(node.name, "thumbnail"))
    preview.asset.attach(io: StringIO.new(png(160, 90)), filename: "#{node.name}.png", content_type: "image/png")
  end

  def png(width, height)
    chunk = ->(type, data) { [ data.bytesize ].pack("N") + type + data + [ Zlib.crc32(type + data) ].pack("N") }
    rows = ([ 0 ] + [ 150, 150, 150 ] * width).pack("C*") * height
    "\x89PNG\r\n\x1a\n".b + chunk.("IHDR", [ width, height, 8, 2, 0, 0, 0 ].pack("NNCCCCC")) +
      chunk.("IDAT", Zlib::Deflate.deflate(rows)) + chunk.("IEND", "".b)
  end
end
