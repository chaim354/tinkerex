# REAL 3MF PACKAGES, BUILT IN RUBY — a plain export, a Bambu Studio project and a PrusaSlicer
# project, for `Maker::ThreeMfManifest` (which parses them) and `test/system/o3dv_test.rb` (where
# three.js's own 3MFLoader really loads them in a browser).
#
# BUILT, NOT COMMITTED, for test/support/mesh_fixture.rb's reason and one more of its own: a 3MF is
# a ZIP OF SEVERAL XML DOCUMENTS THAT REFER TO EACH OTHER BY ID, and the thing under test is
# exactly those cross-references — a build item names a container object, the container names a
# component in another part file, and the slicer's config keys its extruder off BOTH ids. A
# committed blob would hide the relationship the manifest exists to resolve; written out, the ids
# are visible beside the colours they are supposed to produce.
#
# THE BUILD ORDER IS DELIBERATELY NOT THE ID ORDER. `<resources>` lists objects ascending and
# `<build>` lists items in the order the caller passed them, so container ids come out 4 then 2 for
# two objects. That is what a real Bambu project looks like (`keyboard storage.3mf`: resources 2,4;
# build 2,4 — and `Large Wheel-Pair-U1.3mf`: resources 4,8 with parts 1,2,3 and 5,6,7 in two
# separate part files), and it is what makes a walk over `<resources>` instead of `<build>` produce
# a REVERSED colour list rather than the same one by luck.
require "zip"

module ThreeMfFixture
  include MeshFixture

  CORE_NS = "http://schemas.microsoft.com/3dmanufacturing/core/2015/02".freeze
  PRODUCTION_NS = "http://schemas.microsoft.com/3dmanufacturing/production/2015/06".freeze
  REL_TYPE = "http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel".freeze

  # An axis-aligned CUBE rather than the tetrahedron mesh_fixture.rb uses, because these fixtures
  # are viewed as several objects side by side and a cube's silhouette says which is which. Eight
  # vertices, twelve triangles, one corner at the origin.
  def cube_mesh_xml(size: 10)
    s = size.to_f
    v = [ [ 0, 0, 0 ], [ s, 0, 0 ], [ s, s, 0 ], [ 0, s, 0 ],
          [ 0, 0, s ], [ s, 0, s ], [ s, s, s ], [ 0, s, s ] ]
    t = [ [ 0, 2, 1 ], [ 0, 3, 2 ], [ 4, 5, 6 ], [ 4, 6, 7 ],
          [ 0, 1, 5 ], [ 0, 5, 4 ], [ 1, 2, 6 ], [ 1, 6, 5 ],
          [ 2, 3, 7 ], [ 2, 7, 6 ], [ 3, 0, 4 ], [ 3, 4, 7 ] ]
    <<~MESH
      <mesh>
       <vertices>
      #{v.map { |x, y, z| %(  <vertex x="#{x}" y="#{y}" z="#{z}"/>) }.join("\n")}
       </vertices>
       <triangles>
      #{t.map { |a, b, c| %(  <triangle v1="#{a}" v2="#{b}" v3="#{c}"/>) }.join("\n")}
       </triangles>
      </mesh>
    MESH
  end

  # A WELL-FORMED MESH WITH NOTHING IN IT. Legal 3MF, and the one shape where the server's walk and
  # the viewer's model genuinely disagree about how many meshes a file has: the walk counts an
  # `<object>` holding a `<mesh>`, and Online3DViewer's converter drops a mesh with no triangles
  # (`LineCount() === 0 && TriangleCount() === 0`). That is what `bambu_3mf(objects: [{ empty: true }])`
  # is for — a count mismatch the importer still survives, which is what the client's refusal needs
  # in order to be driven at all.
  EMPTY_MESH = "<mesh>\n <vertices/>\n <triangles/>\n</mesh>\n".freeze

  # --- a plain export (no slicer metadata at all) --------------------------------

  # ONE OBJECT, MESH INLINE, NO Metadata/ AT ALL — an Onshape or Shapr3D export. `unit` is the whole
  # point of the parameter: three's loader ignores it, so `unit: "meter"` is the file that measures
  # 1000x short in the viewer without the manifest.
  def plain_3mf(unit: "millimeter", size: 10)
    model = model_document(
      %(  <object id="1" type="model">\n#{indent(cube_mesh_xml(size:), 3)}  </object>),
      items: %(  <item objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>), unit:
    )
    threemf_zip("3D/3dmodel.model" => model)
  end

  # --- a Bambu Studio project ----------------------------------------------------

  # THE SHAPE A REAL BAMBU PROJECT HAS, reproduced because every id relationship in it is load
  # bearing: the root document holds one CONTAINER object per model, each holding a single
  # `<component p:path>` into its own `3D/Objects/object_N.model`; `model_settings.config` keys its
  # `<object id>` on the CONTAINER and its `<part id>` on the object inside the part file; and the
  # filament palette lives in a JSON `project_settings.config`, indexed 1-based by extruder.
  #
  # `objects` is one hash per model: `extruder:` (the object's own, omitted when nil) and
  # `part_extruder:` (the part's, which overrides it — this is how a real project prints one
  # object's lettering in a second filament).
  def bambu_3mf(objects: [ { extruder: 1 }, { extruder: 2 } ],
                filaments: %w[#161616 #F98C36 #FFFFFF],
                unit: "millimeter", size: 10)
    count = objects.size
    entries = {}
    resources = []
    items = []

    objects.each_with_index do |spec, index|
      container = bambu_container_id(index, count)
      leaf = bambu_leaf_id(index)
      part_path = "3D/Objects/object_#{leaf}.model"
      resources << [ container, <<~OBJECT.chomp ]
          <object id="#{container}" type="model">
           <components>
            <component p:path="/#{part_path}" objectid="#{leaf}" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
           </components>
          </object>
      OBJECT
      items << %(  <item objectid="#{container}" transform="1 0 0 0 1 0 0 0 1 #{index * (size + 5)} 0 0" printable="1"/>)
      mesh = spec[:empty] ? EMPTY_MESH : cube_mesh_xml(size:)
      entries[part_path] = model_document(
        %(  <object id="#{leaf}" type="model">\n#{indent(mesh, 3)}  </object>), unit:
      )
    end

    entries["3D/3dmodel.model"] =
      model_document(resources.sort_by(&:first).map(&:last).join("\n"), items: items.join("\n"), unit:)
    entries["3D/_rels/3dmodel.model.rels"] = relationships(entries.keys.grep(%r{\A3D/Objects/}))
    entries["Metadata/model_settings.config"] = bambu_model_settings(objects, count)
    entries["Metadata/project_settings.config"] = JSON.generate("filament_colour" => filaments)
    threemf_zip(entries)
  end

  def bambu_container_id(index, count) = 2 * (count - index)

  def bambu_leaf_id(index) = 100 + index

  # WRITTEN IN DESCENDING ID ORDER, as Bambu writes it, so a reader that took the config's own
  # document order for the build order would pair every extruder with the wrong object.
  def bambu_model_settings(objects, count)
    body = objects.each_with_index.map { |spec, index|
      container = bambu_container_id(index, count)
      leaf = bambu_leaf_id(index)
      <<~OBJECT.chomp
          <object id="#{container}">
            <metadata key="name" value="part-#{index + 1}.stl"/>
        #{spec[:extruder] ? %(    <metadata key="extruder" value="#{spec[:extruder]}"/>) : "    <metadata key=\"face_count\" value=\"12\"/>"}
            <part id="#{leaf}" subtype="normal_part">
              <metadata key="name" value="part-#{index + 1}.stl"/>
        #{spec[:part_extruder] ? %(      <metadata key="extruder" value="#{spec[:part_extruder]}"/>) : "      <metadata key=\"matrix\" value=\"1 0 0 0 0 1 0 0 0 0 1 0 0 0 0 1\"/>"}
            </part>
          </object>
      OBJECT
    }.reverse.join("\n")
    %(<?xml version="1.0" encoding="UTF-8"?>\n<config>\n#{body}\n</config>\n)
  end

  # --- a PrusaSlicer project -----------------------------------------------------

  # PRUSA KEEPS ITS MESHES INLINE — no part files and no components — so the object a build item
  # names IS the object holding the mesh, and `Slic3r_PE_model.config` keys on that one id. The
  # palette is a plain-text config line rather than JSON.
  def prusa_3mf(objects: [ { extruder: 2 } ], extruder_colours: %w[#FF0000 #00FF00],
                filament_colours: nil, unit: "millimeter", size: 10)
    count = objects.size
    resources = []
    items = []
    objects.each_with_index do |_spec, index|
      id = bambu_container_id(index, count)
      resources << [ id, %(  <object id="#{id}" type="model">\n#{indent(cube_mesh_xml(size:), 3)}  </object>) ]
      items << %(  <item objectid="#{id}" transform="1 0 0 0 1 0 0 0 1 #{index * (size + 5)} 0 0" printable="1"/>)
    end

    model = model_document(resources.sort_by(&:first).map(&:last).join("\n"),
                           items: items.join("\n"), unit:)
    threemf_zip("3D/3dmodel.model" => model,
                "Metadata/Slic3r_PE_model.config" => prusa_model_config(objects, count),
                "Metadata/Slic3r_PE.config" => prusa_config(extruder_colours, filament_colours))
  end

  def prusa_model_config(objects, count)
    body = objects.each_with_index.map { |spec, index|
      <<~OBJECT.chomp
          <object id="#{bambu_container_id(index, count)}" type="model">
            <metadata type="object" key="name" value="part-#{index + 1}"/>
        #{spec[:extruder] ? %(    <metadata type="object" key="extruder" value="#{spec[:extruder]}"/>) : "    <metadata type=\"object\" key=\"modifier\" value=\"0\"/>"}
            <volume firstid="0" lastid="11">
              <metadata type="volume" key="name" value="part-#{index + 1}"/>
            </volume>
          </object>
      OBJECT
    }.join("\n")
    %(<?xml version="1.0" encoding="UTF-8"?>\n<config>\n#{body}\n</config>\n)
  end

  # `extruder_colour` IS OFTEN BLANK IN A REAL PROJECT and `filament_colour` carries the colour, so
  # both lines exist here and a test can leave either out.
  def prusa_config(extruder_colours, filament_colours)
    lines = [ "; generated by PrusaSlicer 2.8.0 on 2026-09-06 at 00:00:00 UTC", "" ]
    lines << "; extruder_colour = #{Array(extruder_colours).join(';')}" if extruder_colours
    lines << "; filament_colour = #{Array(filament_colours).join(';')}" if filament_colours
    lines << "; layer_height = 0.2"
    "#{lines.join("\n")}\n"
  end

  # --- the package ---------------------------------------------------------------

  # The three parts every 3MF must carry beside its model: the content types, the package
  # relationship naming the root model, and the model itself. `entries` may add part files and
  # Metadata/*.
  def threemf_zip(entries)
    zip_bytes({
      "[Content_Types].xml" => CONTENT_TYPES,
      "_rels/.rels" => relationships([ "3D/3dmodel.model" ])
    }.merge(entries))
  end

  # ZIP64 IS TURNED OFF FOR THESE ARCHIVES, AND IT IS NOT A TIDY-UP — WITHOUT IT THREE'S 3MFLoader
  # CANNOT OPEN THE FIXTURE AT ALL. Measured, after the whole system suite failed on "Cannot find
  # relationship file `rels` in 3MF archive": rubyzip's `OutputStream` streams, so it writes
  # `0xFFFFFFFF` sizes plus a Zip64 extended-information extra field on EVERY entry, while leaving
  # the classic end-of-central-directory record with real values (a Zip64 EOCD is written only when
  # the numbers actually need one). fflate — which three's loader unzips with — decides whether to
  # read those extra fields from the EOCD ALONE (`o == 4294967295 || c == 65535`), so it takes the
  # `0xFFFFFFFF` sizes literally, slices past the end of the buffer, and throws; the loader's
  # `catch` swallows anything that is not a ReferenceError, leaves `zip` null, and reports the
  # missing `.rels` instead. A real 3MF from OpenSCAD or Bambu carries a proper Zip64 EOCD and is
  # read correctly, which is why only the fixture was affected.
  #
  # A GLOBAL, SAVED AND RESTORED: rubyzip exposes no per-archive switch. Nothing outside the test
  # suite writes a zip in this app (grep: only fixtures do), so the window is a fixture build.
  # test/support/gerber_fixture.rb does NOT need this — JSZip, which the Gerber viewer uses, reads
  # the extra fields regardless of the EOCD.
  def zip_bytes(entries)
    prior = Zip.write_zip64_support
    Zip.write_zip64_support = false
    Zip::OutputStream.write_buffer(StringIO.new("".b)) do |out|
      entries.each do |path, body|
        out.put_next_entry(path)
        out.write(body)
      end
    end.string
  ensure
    Zip.write_zip64_support = prior
  end

  # The members of an existing package, minus one — for the tests that need the importer to build
  # FEWER meshes than the manifest counted (a missing part file), which is the count mismatch the
  # browser must refuse to paint through.
  def threemf_without(body, member)
    kept = {}
    Zip::File.open_buffer(StringIO.new(body.b)) do |zip|
      zip.each { |e| kept[e.name] = e.get_input_stream.read unless e.directory? || e.name == member }
      nil
    end
    zip_bytes(kept)
  end

  CONTENT_TYPES = <<~XML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
     <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
     <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
     <Default Extension="png" ContentType="image/png"/>
     <Default Extension="config" ContentType="application/octet-stream"/>
    </Types>
  XML

  def relationships(targets)
    rels = targets.each_with_index.map { |target, i|
      %( <Relationship Target="/#{target}" Id="rel-#{i + 1}" Type="#{REL_TYPE}"/>)
    }
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      #{rels.join("\n")}
      </Relationships>
    XML
  end

  # The `<model>` envelope. A part file passes no build items and gets `<build/>`, exactly as Bambu
  # writes one.
  def model_document(resources, items: nil, unit: "millimeter")
    build = items ? "<build>\n#{items}\n </build>" : "<build/>"
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <model unit="#{unit}" xml:lang="en-US" xmlns="#{CORE_NS}" xmlns:p="#{PRODUCTION_NS}">
       <resources>
      #{resources}
       </resources>
       #{build}
      </model>
    XML
  end

  def indent(text, spaces) = text.each_line.map { |l| l.strip.empty? ? l : "#{' ' * spaces}#{l}" }.join

  # mesh_fixture.rb's `write_model!`, named for what it writes — a REAL file on disk with a node row
  # whose content_hash matches it, never test_helper's `create_node!` (which would overwrite the
  # bytes with its "x" placeholder the moment the row was made).
  def write_threemf!(name: "project.3mf", body: nil, parent_node_id: nil)
    write_model!(name:, body: body || bambu_3mf, parent_node_id:)
  end
end
