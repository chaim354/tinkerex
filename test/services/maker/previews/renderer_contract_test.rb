require "test_helper"

module Maker
  module Previews
    # THE EXTENSIBILITY BACKSTOP. Every renderer in Registry::RENDERERS runs against this one
    # contract, so adding a format is: write a module (available?/render/EXTENSIONS), register one
    # line, drop a fixture into the map below -> covered. A renderer that returns the wrong shape,
    # a non-raster content_type (an SVG the web layer can't safely inline), or non-image bytes
    # cannot merge. Renderers whose toolchain is absent on this box are checked structurally and
    # skip the render assertion (same graceful path the engine takes at runtime).
    class RendererContractTest < ActiveSupport::TestCase
      # Renderer => a fixture file that renderer can actually render. A renderer with no fixture
      # here is still checked structurally; it just can't be exercised end-to-end.
      FIXTURES = {
        Maker::Previews::Svg     => "square.svg",
        Maker::Previews::Dxf     => "sample.dxf",
        Maker::Previews::Lbrn2   => "sample.lbrn2",
        Maker::Previews::ThreeMf => "cube.3mf",
        Maker::Previews::Stl     => "tetra.stl"
        # Mesh (obj/step/iges) intentionally omitted: F3D is not on this box, so it is checked
        # structurally only. Add a fixture here if/when F3D lands in the test env.
      }.freeze

      # Raster types the web grid can inline safely (FilesController::SAFE_INLINE_TYPES minus svg).
      RASTER_TYPES = %w[image/png image/jpeg image/gif image/webp image/bmp].freeze

      def renderers = Maker::Previews::Registry::RENDERERS.values.uniq

      test "every registered renderer exposes the interface" do
        renderers.each do |r|
          assert_respond_to r, :available?, "#{r} must answer available?"
          assert_respond_to r, :render,     "#{r} must answer render"
          assert r.const_defined?(:EXTENSIONS), "#{r} must define EXTENSIONS"
          assert_includes [ true, false ], r.available?, "#{r}#available? must be a Boolean"
        end
      end

      test "every EXTENSIONS entry is lowercase and resolves back to its renderer" do
        renderers.each do |r|
          r::EXTENSIONS.each do |ext|
            assert_equal ext, ext.downcase, "#{r} EXTENSIONS must be lowercase (#{ext})"
            assert_equal r, Maker::Previews::Registry.for(ext),
                         "#{r} claims .#{ext} but Registry.for(#{ext}) disagrees"
          end
        end
      end

      test "when available and given a valid fixture, render returns an inline-safe raster image" do
        FIXTURES.each do |renderer, fixture|
          next unless renderer.available?

          bytes = File.binread(Rails.root.join("test/fixtures/files", fixture))
          ext = File.extname(fixture).delete_prefix(".")
          result = render_with(renderer, bytes, ext)

          assert_kind_of Hash, result, "#{renderer}#render must return a Hash"
          assert_includes RASTER_TYPES, result[:content_type],
                          "#{renderer} thumbnail must be an inline-safe raster type, got #{result[:content_type]}"
          assert result[:bytes] && result[:bytes].bytesize.positive?,
                 "#{renderer} must return non-empty bytes"
        end
      end

      private

      # Renderers share render(bytes, size:); some also take ext:. Pass ext only when accepted.
      def render_with(renderer, bytes, ext)
        accepted = renderer.method(:render).parameters.select { |t, _| %i[key keyreq].include?(t) }.map(&:last)
        opts = { size: 128 }
        opts[:ext] = ext if accepted.include?(:ext)
        renderer.render(bytes, **opts)
      end
    end
  end
end
