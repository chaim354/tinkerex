# REAL 3D MODEL BYTES, GENERATED RATHER THAN COMMITTED — one per importer family, for
# test/system/o3dv_test.rb, which drives Online3DViewer in a real browser and therefore fetches the
# blob URL for real.
#
# test/system/README.md's house rule for this suite (and the reason test/support/kicad_fixture.rb
# exists next door): `test_helper.rb`'s shared `create_node!` always materialises a literal "x"
# placeholder for a file node — deliberately, since most fixtures never read the bytes back — which
# every importer here would receive as garbage. So these write REAL files and create the node row
# beside them, the same shape `write_kicad_schematic!` uses.
#
# BUILT IN RUBY, NOT DROPPED INTO test/fixtures/files. Two of the three are binary containers whose
# whole point is their internal offsets (the STL's 50-byte facet records, the GLB's chunk lengths),
# and a committed blob would hide an arithmetic mistake behind bytes nobody can read in a diff.
# Written out, each one is checkable against its own spec — and the dimensions each model is
# supposed to report are visible right beside the coordinates that produce them, which is what
# `o3dv_test.rb`'s dims assertions actually check.
#
# THREE FORMATS, THREE DIFFERENT IMPORTERS ON PURPOSE (the point of the file): `.stl` is
# Online3DViewer's own binary reader, `.ply` its own ASCII reader, `.glb` its glTF reader. A suite
# that proved only STL would prove the engine boots and nothing about the widening this fixture
# exists to cover.
module MeshFixture
  # --- Binary STL: an 80-byte header, a uint32 facet count, then 50 bytes per facet (12 little-
  # endian floats — normal, then three vertices — and a uint16 attribute word). A TETRAHEDRON, not
  # the single triangle a "minimal" STL usually is: one facet is FLAT, and a flat model gives a
  # bounding box with a zero extent, which makes both the dims assertion and the viewer's own
  # framing degenerate. Four facets over (0,0,0), (20,0,0), (0,10,0), (0,0,5).
  STL_DIMS = "20 × 10 × 5 mm".freeze

  def binary_stl
    a = [ 0.0, 0.0, 0.0 ]
    b = [ 20.0, 0.0, 0.0 ]
    c = [ 0.0, 10.0, 0.0 ]
    d = [ 0.0, 0.0, 5.0 ]
    facets = [ [ a, b, c ], [ a, b, d ], [ a, c, d ], [ b, c, d ] ]

    out = +"".b
    out << "tinkerex test tetrahedron".ljust(80, "\0").b   # the header is free-form and ignored
    out << [ facets.size ].pack("V")
    facets.each do |(v1, v2, v3)|
      # A ZERO NORMAL IS LEGAL AND IS WHAT EVERY READER PREFERS HERE: the spec says a reader may
      # recompute the normal from the winding, and every one of ours does. Writing a wrong normal
      # would be worse than writing none.
      out << [ 0.0, 0.0, 0.0, *v1, *v2, *v3 ].pack("e12")
      out << [ 0 ].pack("v")
    end
    out
  end

  # --- ASCII PLY: the header names the element counts and each property in order, `end_header`
  # closes it, and the body is vertices then faces. Same tetrahedron shape and the same reason for
  # it, at a different size so a test cannot pass by rendering the STL twice.
  PLY_DIMS = "30 × 15 × 6 mm".freeze

  PLY = <<~PLY_BODY.freeze
    ply
    format ascii 1.0
    comment tinkerex test tetrahedron
    element vertex 4
    property float x
    property float y
    property float z
    element face 4
    property list uchar int vertex_indices
    end_header
    0 0 0
    30 0 0
    0 15 0
    0 0 6
    3 0 1 2
    3 0 1 3
    3 0 2 3
    3 1 2 3
  PLY_BODY

  # --- GLB: the binary glTF container — a 12-byte header ("glTF", version 2, total length) then
  # length-prefixed chunks, JSON first and BIN second. ONE TRIANGLE here rather than a tetrahedron,
  # because glTF is Y-UP by specification and the viewer leaves it that way: the flat extent is Z,
  # which is the axis pointing at the camera, so nothing is edge-on and the dims read cleanly.
  #
  # EVERY LENGTH AND OFFSET IS COMPUTED, NOT WRITTEN DOWN. A GLB with a chunk length that
  # disagrees with its payload is rejected before any of it is parsed, and hard-coded numbers are
  # exactly what rots when the JSON gains a key.
  GLB_DIMS = "40 × 20 × 0 mm".freeze

  def glb
    positions = [ 0.0, 0.0, 0.0, 40.0, 0.0, 0.0, 0.0, 20.0, 0.0 ].pack("e9")
    indices   = [ 0, 1, 2 ].pack("v3")
    # The index bufferView must start on a multiple of its component size (2); 36 already is.
    bin = positions + indices
    bin += "\0" * ((4 - (bin.bytesize % 4)) % 4)

    json = {
      asset: { version: "2.0", generator: "tinkerex test" },
      scene: 0,
      scenes: [ { nodes: [ 0 ] } ],
      nodes: [ { mesh: 0 } ],
      meshes: [ { primitives: [ { attributes: { POSITION: 0 }, indices: 1 } ] } ],
      buffers: [ { byteLength: bin.bytesize } ],
      bufferViews: [
        { buffer: 0, byteOffset: 0, byteLength: positions.bytesize, target: 34962 },
        { buffer: 0, byteOffset: positions.bytesize, byteLength: indices.bytesize, target: 34963 }
      ],
      accessors: [
        # min/max are REQUIRED on a POSITION accessor by the spec, and are what a loader may use
        # for its own bounding box rather than walking the buffer.
        { bufferView: 0, componentType: 5126, count: 3, type: "VEC3",
          min: [ 0, 0, 0 ], max: [ 40, 20, 0 ] },
        { bufferView: 1, componentType: 5123, count: 3, type: "SCALAR" }
      ]
    }.to_json.b
    json += " " * ((4 - (json.bytesize % 4)) % 4) # JSON pads with SPACES, BIN pads with NULs

    body = [ json.bytesize, 0x4E4F534A ].pack("VV") + json +
           [ bin.bytesize, 0x004E4942 ].pack("VV") + bin
    [ 0x46546C67, 2, 12 + body.bytesize ].pack("VVV") + body
  end

  # A minimal ISO-10303-21 (STEP) file: a well-formed envelope with an EMPTY DATA section.
  #
  # DELIBERATELY NOT A REAL SOLID, and o3dv_test.rb says so where it uses this. A valid STEP with
  # geometry runs to hundreds of lines of B-rep entities, and the claim that file would let us make
  # — "OpenCascade parses this" — is not the claim worth testing here. What this fixture buys is
  # the path: a `.step` page reaches the `:model3d` branch, the controller launches, and the engine
  # asks for the LOCAL occt worker rather than jsdelivr. Whether the wasm itself instantiates is
  # proven separately in that file, by running the worker directly.
  STEP = <<~STEP_BODY.freeze
    ISO-10303-21;
    HEADER;
    FILE_DESCRIPTION((''),'2;1');
    FILE_NAME('bracket.step','2026-09-06T00:00:00',(''),(''),'','','');
    FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 3 1 1 }'));
    ENDSEC;
    DATA;
    ENDSEC;
    END-ISO-10303-21;
  STEP_BODY

  # A REAL FILE ON DISK with a node row whose content_hash matches it — mirrors
  # test/support/kicad_fixture.rb's `write_kicad_schematic!` exactly, and for the identical reason
  # its own comment gives: `nodes.create!`, NOT test_helper's `create_node!`, which materialises
  # its own "x" placeholder and would overwrite the real bytes immediately after writing them.
  def write_model!(name:, body:, parent_node_id: nil)
    parent = parent_node_id && @user.nodes.find_by(node_id: parent_node_id)
    rel = parent&.storage_path.present? ? File.join(parent.storage_path, name) : name
    path = @root.join(rel)
    path.dirname.mkpath
    path.binwrite(body)
    @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file", parent_node_id:,
                        size: body.bytesize, storage_path: rel, mtime: 1_000_000_000,
                        content_hash: Digest::SHA256.hexdigest(body))
  end
end
