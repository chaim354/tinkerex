require "test_helper"

module Maker
  module Previews
    class EmbeddedThumbnailTest < ActiveSupport::TestCase
      # A 1x1 PNG, base64. Used both raw and embedded in a <Thumbnail Source="..."> attribute.
      PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==".freeze

      test "extracts a base64 PNG from a <Thumbnail Source> attribute" do
        xml = %(<Root><Thumbnail Source="#{PNG_B64}"/></Root>)
        result = Maker::Previews::EmbeddedThumbnail.extract(xml)
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG\r\n\x1A\n".b, result[:bytes][0, 8].b
        assert_equal 1, result[:width]
        assert_equal 1, result[:height]
      end

      test "nil when there is no Thumbnail element" do
        assert_nil Maker::Previews::EmbeddedThumbnail.extract("<Root><Shape/></Root>")
      end

      test "nil when the Source is not a PNG" do
        not_png = Base64.strict_encode64("just some text, not an image")
        xml = %(<Root><Thumbnail Source="#{not_png}"/></Root>)
        assert_nil Maker::Previews::EmbeddedThumbnail.extract(xml)
      end

      test "tolerates non-UTF-8 bytes in the surrounding file" do
        xml = %(<Root>\xFF\xFE<Thumbnail Source="#{PNG_B64}"/></Root>).b
        assert_not_nil Maker::Previews::EmbeddedThumbnail.extract(xml)
      end
    end
  end
end
