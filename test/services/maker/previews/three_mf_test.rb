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

      test "raises NoThumbnail when the 3MF has neither an embedded thumbnail nor a mesh" do
        # @nothumb has no embedded PNG AND no <mesh> — so both paths fail. (A 3MF WITH a mesh but
        # no thumbnail renders via the mesh fallback; see the mesh tests below.)
        assert_raises(Maker::Previews::ThreeMf::NoThumbnail) do
          Maker::Previews::ThreeMf.render(@nothumb, size: 512)
        end
      end

      # A minimal 3MF (OPC zip) carrying a tetrahedron mesh and NO embedded thumbnail — exercises
      # the mesh-render fallback (the common case for CAD-exported 3MFs).
      def tetra_3mf
        model = <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
            <resources><object id="1" type="model"><mesh>
              <vertices>
                <vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/>
                <vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/>
              </vertices>
              <triangles>
                <triangle v1="0" v2="1" v3="2"/><triangle v1="0" v2="1" v3="3"/>
                <triangle v1="0" v2="2" v3="3"/><triangle v1="1" v2="2" v3="3"/>
              </triangles>
            </mesh></object></resources>
            <build><item objectid="1"/></build>
          </model>
        XML
        Zip::OutputStream.write_buffer do |z|
          z.put_next_entry("3D/3dmodel.model")
          z.write(model)
        end.string.b
      end

      test "mesh_to_stl converts the 3MF mesh to a valid binary STL" do
        stl = Maker::Previews::ThreeMf.mesh_to_stl(tetra_3mf)
        assert_not_nil stl
        # Binary STL: 80-byte header + uint32 triangle count + 50 bytes/triangle. 4 triangles.
        assert_equal 4, stl[80, 4].unpack1("V")
        assert_equal 84 + (4 * 50), stl.bytesize
      end

      test "mesh_to_stl is nil for a 3MF with no mesh" do
        assert_nil Maker::Previews::ThreeMf.mesh_to_stl(@nothumb)
      end

      test "render falls back to the mesh when there is no embedded thumbnail" do
        skip "stl-thumbnailer not installed on this box" unless Maker::Previews::Stl.available?

        result = Maker::Previews::ThreeMf.render(tetra_3mf, size: 256)
        assert_equal "image/png", result[:content_type]
        assert_equal "\x89PNG".b, result[:bytes][0, 4].b
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
