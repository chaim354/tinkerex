require "test_helper"

module Maker
  module Previews
    class ThreeMfTest < ActiveSupport::TestCase
      setup do
        @threemf  = File.binread(Rails.root.join("test/fixtures/files/cube.3mf"))
        @nothumb  = File.binread(Rails.root.join("test/fixtures/files/nothumb.3mf"))
      end

      test "is always available (pure-Ruby zip read, no native rasterizer)" do
        assert Maker::Previews::ThreeMf.available?
      end

      test "extracts the embedded thumbnail PNG as the preview asset" do
        result = Maker::Previews::ThreeMf.render(@threemf, size: 512)
        assert_equal "image/png", result[:content_type]
        # PNG magic number — the embedded image is returned verbatim.
        assert_equal "\x89PNG".b, result[:bytes][0, 4].b
      end

      test "reports the embedded PNG's natural dimensions" do
        result = Maker::Previews::ThreeMf.render(@threemf, size: 512)
        assert_equal 4, result[:width]
        assert_equal 4, result[:height]
      end

      test "raises NoThumbnail when the 3MF has no embedded thumbnail" do
        assert_raises(Maker::Previews::ThreeMf::NoThumbnail) do
          Maker::Previews::ThreeMf.render(@nothumb, size: 512)
        end
      end

      test "raises NoThumbnail on bytes that are not a readable zip" do
        assert_raises(Maker::Previews::ThreeMf::NoThumbnail) do
          Maker::Previews::ThreeMf.render("not a zip at all".b, size: 512)
        end
      end

      test "resolves the OPC thumbnail relationship target" do
        # The fixture also declares the thumbnail via _rels/.rels — confirm the resolver finds it.
        target = nil
        Zip::File.open_buffer(StringIO.new(@threemf)) do |zip|
          target = Maker::Previews::ThreeMf.thumbnail_from_rels(zip)
        end
        assert_equal "Metadata/thumbnail.png", target
      end
    end
  end
end
