require "application_system_test_case"
require_relative "../support/fake_openscad"

# THE THING USERS ACTUALLY LOST: the OpenSCAD editor renders the generator's defaults on arrival,
# with nobody pressing Preview.
#
# WHY THIS TIER AND NOTHING CHEAPER. boxpreview_controller.js was deleted in 6095b87 while
# new.html.erb went on declaring it, and Stimulus no-ops SILENTLY on an identifier it cannot
# resolve. The whole failure lives in the browser: the controller has to be REGISTERED (importmap
# `pin_all_from` + `eagerLoadControllersFrom`, which no Ruby test exercises), it has to CONNECT, and
# only then does it issue the POST. test/controllers/tools/openscad_controller_test.rb POSTs that
# endpoint directly and stayed green for nine days over an editor whose preview never fired — a
# request test can prove the endpoint works and nothing at all about whether anything calls it.
#
# test/stimulus_hygiene_test.rb is the cheap, repo-wide half and proves the controller EXISTS. This
# file is the other half: that it does its job.
#
# TWO SEAMS ARE STUBBED, AND THEY ARE STUBBED FOR DIFFERENT REASONS.
#
#   1. THE SIDECAR, at `OpenscadClient.stub` — the seam openscad_controller_test.rb and
#      file_chooser_test.rb already use. There is no Python sidecar in CI.
#   2. THE RASTERIZER, at `Maker::Previews::ThreeMf.render`. This one is NOT about the sidecar: a
#      sidecar-produced 3MF carries no embedded slicer thumbnail, so `#rasterize` always falls
#      through to the mesh path, which shells out to the `stl-thumbnailer` BINARY — absent on this
#      box and on the CI runner. Unstubbed, the endpoint answers a perfectly correct 422 ("the model
#      rendered, but no preview image could be made") and "an image appeared" becomes a test that
#      can never pass for a reason having nothing to do with the bug.
#
# Stubbing the rasterizer costs no coverage: openscad_controller_test.rb's "preview rasterizes the
# rendered 3MF server-side, and says so when it cannot" already drives the REAL `#rasterize` on both
# of its branches. It is deliberately NOT faked by handing FakeOpenscad a 3MF that happens to embed
# a thumbnail — that would quietly send the server down a branch production never takes, and a fake
# diverging from the real wire format is this repo's recorded way of confirming a bug rather than
# catching it (CLAUDE.md §14e). Everything between the browser and that binary — importmap
# registration, `connect()`, CSRF, routing, `#preview`, `source_text!`, the port — runs for real.
class OpenscadPreviewTest < ApplicationSystemTestCase
  include WebHelpers

  # A real PNG off disk rather than invented bytes: the browser has to DECODE what the blob URL
  # points at, and an <img> whose src never decodes looks identical to one that was never set.
  RASTER = {
    bytes: Rails.root.join("test/fixtures/files/sample.png").binread,
    content_type: "image/png", width: nil, height: nil
  }.freeze

  # The deliberate 422 the refusal test provokes. Chrome logs ANY failed fetch at SEVERE, so without
  # this the expected refusal would mask a genuine error logged beside it — the same argument
  # box_sections_test's SAMPLE_404/GENERATE_422 already make.
  PREVIEW_422 = %r{/tools/openscad/preview - Failed to load resource.+422}

  # The sidecar refusing a submitted VALUE. `InvalidParams` is what OpenscadClient raises when the
  # sidecar tags its 422 with `code: "invalid_params"`, and the message is coerce.py's own prose.
  class RefusingOpenscad < FakeOpenscad
    COMPLAINT = "cols: expected an integer, got \"lots\"".freeze

    def render(scad:, params:, format: "3mf")
      raise OpenscadClient::InvalidParams, COMPLAINT
    end
  end

  setup do
    # OpenscadClient.current prefers @stub over the URL, so nothing here reaches the network — but
    # the addon GREYS OUT when no URL is configured (`require_openscad!`), so the page still has to
    # look like a deployment that has one.
    @prior_sidecar_url = ENV["OPENSCAD_SIDECAR_URL"]
    ENV["OPENSCAD_SIDECAR_URL"] = "http://openscad.invalid"
    OpenscadClient.stub = FakeOpenscad.new
    sign_in_as "openscad-preview@example.com"
  end

  teardown do
    ENV["OPENSCAD_SIDECAR_URL"] = @prior_sidecar_url
    OpenscadClient.reset!
  end

  # Swaps the rasterizer for the duration of a block. HAND-ROLLED because minitest 6 dropped
  # `minitest/mock`, and with it `Object#stub`; this repo does not carry the separate gem. Restored
  # in an `ensure` — a leaked singleton override would silently follow every later test in this
  # process, which is worse than the missing binary it works around. Visible from the Puma thread
  # because a system test's server runs in the same process.
  def with_rasterizer(result)
    target = Maker::Previews::ThreeMf
    original = target.method(:render)
    target.define_singleton_method(:render) { |_bytes, **_opts| result }
    yield
  ensure
    target.define_singleton_method(:render, original)
  end

  # MUTATION-CHECKED: removed the `this.preview()` call at the end of boxpreview_controller's
  # `connect()` — RED here ("the editor never previewed the generator's defaults"), while every
  # other test in the suite stayed green. Deleting the controller file outright is the original bug
  # and is red here too.
  test "the editor previews the generator's defaults with nothing clicked" do
    with_rasterizer(RASTER) do
      visit new_tools_openscad_path(generator: "hex_plate")

      # `visible: :all` — the <img> has no src yet, so it has no box and Capybara would not find it.
      img = find('[data-boxpreview-target="image"]', visible: :all)
      wait_until(message: "the editor never previewed the generator's defaults") do
        img[:src].to_s.start_with?("blob:")
      end

      # THE SRC ALONE IS NOT ENOUGH — a blob holding a 404 page or an unreadable body still yields a
      # `blob:` URL. `naturalWidth` is non-zero only once the browser has actually DECODED an image,
      # which is the user-visible claim: a picture appeared in the panel.
      wait_until(message: "the preview <img> never decoded the bytes it was handed") do
        page.evaluate_script(
          "document.querySelector('[data-boxpreview-target=\"image\"]').naturalWidth > 0"
        )
      end
      assert_selector ".box-editor.has-preview"
      assert_no_console_errors
    end
  end

  # THE SIDECAR'S OWN SENTENCE, NOT A STATUS CODE — and it is the half the restored controller could
  # not have delivered on its own: new.html.erb shipped no `status` target, and #status returns early
  # without one, so a refused value was swallowed and the panel simply stayed blank. Guards the
  # element as much as the code path.
  test "a value the sidecar refuses reaches the user in the sidecar's own words" do
    OpenscadClient.stub = RefusingOpenscad.new
    visit new_tools_openscad_path(generator: "hex_plate")

    # `.is-error`, not merely the text: this element also carries "Rendering…", and a refusal styled
    # as ordinary progress is a refusal the user reads straight past.
    assert_selector '[data-boxpreview-target="status"].is-error',
                    exact_text: RefusingOpenscad::COMPLAINT
    assert_no_console_errors ignoring: [ PREVIEW_422 ]
  end
end
