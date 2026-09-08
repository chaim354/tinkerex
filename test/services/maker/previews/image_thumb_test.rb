require "test_helper"

module Maker
  module Previews
    # THE TWO DECODERS BEHIND tinkerex#285, PROVED ON THE BOX THAT RUNS THE SUITE. `ImageThumb`
    # shells out to vipsthumbnail, and whether it can open a `.heic` (libheif) or a `.tif` (libtiff)
    # is a property of the libvips build, not of this code — so each is rendered from a real
    # fixture (8×8, written by `vips copy`) and the result checked for PNG bytes. Skipped, not
    # failed, on a box without the binary, the way pdf_test.rb treats pdfium.
    class ImageThumbTest < ActiveSupport::TestCase
      { "heic" => "sample.heic", "tif" => "sample.tif" }.each do |ext, fixture|
        test "renders a .#{ext} fixture to a PNG through libvips" do
          skip "vipsthumbnail not installed" unless Maker::Previews::ImageThumb.available?

          bytes = File.binread(Rails.root.join("test/fixtures/files", fixture))
          result = Maker::Previews::ImageThumb.render(bytes, size: 64, ext:)

          assert_equal "image/png", result[:content_type]
          assert result[:bytes].b.start_with?("\x89PNG".b), "a .#{ext} must come back as a PNG"
          assert_operator result[:width], :>, 0
        end
      end
    end
  end
end
