require "application_system_test_case"
require "support/mesh_fixture"

# "USE THIS FRAME AS PREVIEW" IN A REAL BROWSER (2026-11-22, videoframe_controller.js). The fixture
# is 2 s of 160x90 VP8 (libvpx, BSD), red for the first second and blue for the second, so a pixel
# of the stored PNG says WHICH frame was taken: the seeked one, not the first one a player shows.
# The request half (which pages offer it, the tiles, the poll, Remove) is
# test/integration/web/video_frame_preview_test.rb.
#
# SHARE ONLY, AS EVERY SYSTEM TEST IS (config/ci.rb): the player is same-origin and its own frame is
# drawn. The s3 arm — a cross-origin player whose canvas is tainted, and the crossorigin twin read in
# its place — needs a real bucket with a CORS rule, and was measured against SeaweedFS instead (PR).
class VideoFrameTest < ApplicationSystemTestCase
  include MeshFixture # write_model!

  FIXTURE = Rails.root.join("test/fixtures/files/two-colour.webm")
  RED = [ 255, 0, 0 ].freeze
  BLUE = [ 0, 0, 255 ].freeze

  setup do
    @root = use_fresh_share_library!
    @user = sign_in_as("videoframe@example.com")
    @clip = write_model!(name: "jig.webm", body: FIXTURE.binread)
  end

  teardown do
    FileLayer.reset!
    FileUtils.remove_entry(@root) if @root&.exist?
  end

  # The centre pixel of a same-origin image, decoded by the browser. VP8 is lossy, so a channel is
  # read as on (> 200) or off (< 60) rather than compared exactly.
  def centre_colour(src)
    rgb = page.evaluate_async_script(<<~JS, src)
      const done = arguments[arguments.length - 1];
      const probe = new Image();
      probe.onload = () => {
        const c = document.createElement("canvas"); c.width = probe.width; c.height = probe.height;
        const ctx = c.getContext("2d"); ctx.drawImage(probe, 0, 0);
        done(Array.from(ctx.getImageData(probe.width >> 1, probe.height >> 1, 1, 1).data).slice(0, 3));
      };
      probe.onerror = () => done(null);
      probe.src = arguments[0];
    JS
    rgb&.map { |v| v > 200 ? 255 : (v < 60 ? 0 : v) }
  end

  def seek_player_to(seconds)
    page.execute_script("document.querySelector('.video-viewer video').currentTime = arguments[0]", seconds)
    wait_until(message: "the player never reached #{seconds}s") do
      page.evaluate_script("(v => !v.seeking && v.currentTime === #{seconds} && v.readyState >= 2)(document.querySelector('.video-viewer video'))")
    end
  end

  def saved_row = @user.maker_previews.find_by(node_id: @clip.node_id, kind: "thumbnail")

  test "the frame on screen becomes the file's tile in the Library" do
    visit file_path(@clip.node_id)
    seek_player_to(1.5)
    click_on "Use this frame as preview"
    assert_selector "[data-videoframe-target='status']", text: "Saved this frame as the preview."

    row = saved_row
    assert_equal [ "viewer", "ready", 160, 90 ], [ row.source, row.status, row.width, row.height ],
                 "a 160x90 clip is stored at its own size, never blown up to 512"
    assert_equal BLUE, centre_colour(rails_blob_path(row.asset, only_path: true)), "the SEEKED frame, not the first"

    visit files_path(view: "grid")
    tile = find(".grid-card.file-cell[data-node-id='#{@clip.node_id}'] .thumb.photo img")
    wait_until(message: "the tile's picture never loaded") { tile.evaluate_script("this.complete && this.naturalWidth > 0") }
    assert_equal BLUE, centre_colour(tile[:src])
    assert_no_console_errors
  end

  # A PLAYER THAT HAS LOADED NOTHING IS ASKED TO. `preload="none"` is what iOS Safari treats every
  # element as: it waits for a play or a seek before fetching a byte, so a capture that only waited
  # for metadata would wait for good. The click itself must start the load.
  test "a player holding nothing yet is loaded, and its first frame saved" do
    visit file_path(@clip.node_id)
    page.execute_script(<<~JS)
      const v = document.querySelector('.video-viewer video');
      v.preload = 'none'; v.src = v.getAttribute('src');
    JS
    wait_until(message: "the player still held data") { page.evaluate_script("document.querySelector('.video-viewer video').readyState") == 0 }

    click_on "Use this frame as preview"
    assert_selector "[data-videoframe-target='status']", text: "Saved this frame as the preview."
    assert_equal RED, centre_colour(rails_blob_path(saved_row.asset, only_path: true))
    assert_no_console_errors
  end

  # A CANVAS THE PLAYER PAINTED NOTHING INTO IS REFUSED, NOT ENCODED. Measured in Chrome on a tab
  # not on screen: a paused player reported HAVE_ENOUGH_DATA, drew nothing, tainted nothing, and a
  # transparent PNG became the tile. frameReady's seek is what keeps that from happening; this is
  # the check behind it, reached on demand with an element that holds no frame at all.
  test "a player that draws no picture is refused rather than saved as a blank tile" do
    visit file_path(@clip.node_id)
    outcome = page.evaluate_async_script(<<~JS)
      const done = arguments[arguments.length - 1];
      import("controllers/videoframe_controller").then(({ framePng }) =>
        framePng(document.createElement("video")).then(
          (blob) => done("encoded " + blob.size + " bytes"),
          (error) => done(error.constructor.name + ": " + error.message)))
    JS
    assert_equal "NoPicture: the player drew no picture", outcome
  end
end
