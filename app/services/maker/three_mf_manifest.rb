require "zip"

module Maker
  # WHAT A SLICER SAID ABOUT A 3MF THAT THE 3MF FORMAT ITSELF DOES NOT CARRY — read here, once, and
  # handed to the browser as data, because the viewer's importer (three.js's 3MFLoader, wrapped by
  # Online3DViewer) cannot know it and never will: Bambu Studio and PrusaSlicer keep a project's
  # filament colours and per-object extruder in their own Metadata/*.config files, and three's
  # loader also ignores the model's declared `unit` (measured: an Onshape export in metres came out
  # 1000x short on the dims line; docs/superpowers/plans/2026-09-06-threemf-colours.md).
  #
  # THE ANSWER IS ORDERED THE WAY THE ENGINE IMPORTS: one colour per LEAF MESH, in `<build><item>`
  # order with components resolved depth-first — the order three's loader creates meshes and
  # Online3DViewer's converter numbers them. The browser matches by that index
  # (`userData.originalMeshInstance.id.meshIndex`), never by name: Bambu's `<object>` carries no
  # `name` attribute at all (the name lives in model_settings.config), so a name match would apply
  # nothing. RESOURCE ORDER IS NOT BUILD ORDER — a real Bambu project writes its objects ascending
  # and its build items in plate order, so walking `<resources>` paints the parts in the wrong
  # colours. A count mismatch on the client applies NOTHING: a wrong colour on the wrong part is
  # worse than grey.
  #
  # ONE BOUNDED PORT READ, CACHED BY CONTENT TOKEN, NIL INCLUDED — Maker::GerberArchive's shape and
  # its argument: judged on the catalog's own `size` first (an unknown size is refused, because
  # `nil.to_i` is 0 and would pass the guard into the port's own 256 MB cap), never opened past
  # READ_LIMIT, and a file that answers nil stays nil until its bytes change.
  #
  # NOT HANDLED, ON PURPOSE FOR NOW: painted triangles (Bambu `paint_color`, PrusaSlicer
  # `slic3rpe:mmu_segmentation`). Those are per-triangle extruder assignments three's loader drops
  # on import; honouring them needs a custom parse into per-triangle materials, a different piece of
  # work. Volumes in a PrusaSlicer object with their own extruder are likewise triangle RANGES of
  # one mesh — the object's extruder is used for the whole mesh. (A Bambu "part" is a whole mesh of
  # its own, so a part-level extruder IS honoured; that is the difference, not an inconsistency.)
  #
  # EVERY FAILURE COLLAPSES TO nil — not a zip, no 3dmodel.model, malformed XML, unreadable store —
  # because every caller answers all of them the same way (no colours, factor 1). `rescue` names
  # the port's two plus Zip::Error and Nokogiri's SyntaxError, never a bare rescue: a NoMethodError
  # here is a bug and must stay loud.
  class ThreeMfManifest
    Manifest = Data.define(:unit_factor, :colors)

    # ONE IMPORTED MESH. `item_object_id` is the id of the object the BUILD ITEM named — which is
    # what a slicer's config keys its per-object settings on — and `mesh_object_id` is the id of the
    # object actually holding the mesh, inside `path`, which is what a Bambu `<part id>` names.
    # For a plain export with the mesh inline they are the same id; for a Bambu project they never
    # are, and collapsing them finds no config object at all. NOT SPELLED `object_id`: a Data member
    # of that name overrides `Object#object_id`, and Ruby warns "redefining 'object_id' may cause
    # serious problems" on every boot (probed, not guessed).
    Leaf = Data.define(:item_object_id, :mesh_object_id, :path)

    EXT = "3mf".freeze
    # A slicer project is the model plus its plate thumbnails and settings; the library's largest is
    # 14 MB. 64 MB is well past any of them, and past it the read would stream that much off the
    # user's store per page view. (Measured: parsing the two 6.8 MB part documents of a real Bambu
    # project takes 0.2 s, so the DOM parse is not what this bound is protecting against.)
    READ_LIMIT = 64 * 1024 * 1024
    CACHE_TTL = 30.days

    # The 3MF core spec's unit vocabulary, to millimetres. Absent or unknown -> 1 (the spec's own
    # default is millimeter).
    UNIT_TO_MM = {
      "micron" => 0.001, "millimeter" => 1.0, "centimeter" => 10.0,
      "inch" => 25.4, "foot" => 304.8, "meter" => 1000.0
    }.freeze

    ROOT_MODEL = "3D/3dmodel.model".freeze
    # `p:path` lives in the 3MF production extension's namespace. Looked up with the namespace AND
    # by bare name, because a producer may bind the prefix to anything and Nokogiri's `[]` answers
    # on the qualified name.
    PRODUCTION_NS = "http://schemas.microsoft.com/3dmanufacturing/production/2015/06".freeze
    # A component that resolves to an object that resolves to a component... A real file nests one
    # level; this only has to refuse a cycle, not support deep assemblies.
    MAX_DEPTH = 16
    # Objects visited across one whole walk, every build item included — a bound on WORK where
    # MAX_DEPTH bounds only nesting (see `walk`). A real project is dozens; a thousand-part assembly
    # is hundreds; ten thousand is a file nobody printed.
    MAX_STEPS = 10_000

    def self.threemf?(name) = File.extname(name.to_s).downcase.delete(".") == EXT

    # nil unless this node is a 3MF we could read something from. `user` is whose library the bytes
    # are read from — the file page's current user; nothing public reads a manifest.
    #
    # THE TOKEN IS `content_hash` OR `current_version_id`, the port's own `content_token` spelled
    # from the catalog: a hash on share/s3, a version id on chunk_remote. Read off the two columns
    # rather than asking the port for `stat`, which would cost a second call per page view just to
    # build a cache key.
    def self.for(user:, node:)
      return nil unless threemf?(node.name)
      return nil if node.size.nil? || node.size > READ_LIMIT

      token = node.content_hash.presence || node.current_version_id.presence
      Rails.cache.fetch([ "threemf-manifest", node.node_id, token ], expires_in: CACHE_TTL) do
        read(user:, node:)
      end
    end

    def self.read(user:, node:)
      manifest_from(FileLayer.current.read(user, node_id: node.node_id))
    rescue FileLayer::NotFound, FileLayer::FetchError
      nil
    end

    # PUBLIC AND PURE so the tests hand it bytes; `for` is the cached, port-reading door.
    #
    # BOTH EXITS FROM THE BLOCK ARE AN EXPLICIT `return`, as in Maker::GerberArchive and for its
    # reason: `Zip::File.open_buffer` DISCARDS its block's value and answers `zf.write_buffer(io)`
    # instead (rubyzip 3.6.0), so a Manifest left as the block's last expression is thrown away and
    # this method hands its caller a StringIO — which then fails at the cache as `TypeError: no
    # _dump_data is defined for class StringIO`, nowhere near the mistake. The zero-length guard is
    # the same class's probed finding: `open_buffer` on an empty buffer raises TypeError, not
    # Zip::Error.
    def self.manifest_from(bytes)
      zip = open_zip(bytes) or return nil
      root = xml(zip, ROOT_MODEL)
      return nil unless root && root.name == "model"

      factor = UNIT_TO_MM.fetch(root["unit"].to_s.downcase, 1.0)
      leaves = leaf_meshes(zip, root)
      colors = Slicer.for(zip)&.colors_for(leaves) || Array.new(leaves.size)
      Manifest.new(unit_factor: factor, colors:)
    rescue Nokogiri::XML::SyntaxError
      nil
    end

    # THE ARCHIVE IS OPENED IN A RESCUE OF ITS OWN, NARROWER IN SCOPE AND WIDER IN CLASSES than the
    # method's. rubyzip 3.6.0 does not fail cleanly on a central directory that is present but cut
    # short: a real 3MF minus its last 1, 5 or 10 bytes raised `NoMethodError` ("undefined method
    # 'positive?' for nil") and `ArgumentError` ("comparison of Integer with nil") out of
    # `open_buffer`, not `Zip::Error` (the review measured it; only a zip minus 20 bytes, its whole
    # EOCD gone, answered `Zip::Error`). A method-level `rescue NoMethodError` would also swallow
    # THIS class's own bugs, which must stay loud — so the wide list wraps exactly the one call that
    # is the gem's, and nothing else. The block form is not used: it discards the block's value and
    # answers a re-serialised buffer (`zf.write_buffer`), so the archive is taken by return value.
    # Empty bytes are refused first: `open_buffer` on them raises TypeError, and a file with no bytes
    # is not a 3MF either way.
    def self.open_zip(bytes)
      return nil if bytes.nil? || bytes.empty?

      Zip::File.open_buffer(StringIO.new(bytes.b))
    rescue Zip::Error, TypeError, NoMethodError, ArgumentError
      nil
    end

    # --- the walk ----------------------------------------------------------------

    # THE BUILD IS THE ORDER, not the resource list. Every leaf carries the id of the item that
    # reached it, because that is the id a slicer's config keys on.
    def self.leaf_meshes(zip, root)
      parts = { ROOT_MODEL => index_objects(root) }
      build = child(root, "build")
      return [] if build.nil?

      budget = { steps: MAX_STEPS }
      elements(build, "item").flat_map do |item|
        id = item["objectid"].to_s
        walk(zip, parts, ROOT_MODEL, id, id, 0, budget)
      end
    end

    # An object holding a `<mesh>` is one imported mesh; an object holding `<components>` is none of
    # its own and every component's, in component order, each resolved in the part file its own
    # `p:path` names (relative to the zip root). A component naming a part file this zip does not
    # hold emits nothing. That choice is NOT what keeps the counts aligned — measured, three's loader
    # fails the WHOLE import on a missing part, so the browser never reaches `applyColors` and this
    # list is moot for such a file; skipping is chosen only so that nothing raises here.
    #
    # `<mesh>` IS REQUIRED FOR A LEAF rather than "no components": an object with neither (a 3MF may
    # carry one) would otherwise be counted as a mesh the importer never made, and the count check
    # on the client would then refuse the whole file's colours.
    #
    # BOUNDED TWICE, BECAUSE A DEPTH LIMIT ALONE DOES NOT BOUND THE WORK. `depth` caps nesting at
    # MAX_DEPTH; `budget` is a total step count across the whole walk, every build item included,
    # and it is the one that matters: a self-referencing object with three components is 3^16 walks
    # under a depth bound alone — the review measured it not finishing in 20 s, on a request thread,
    # per page view — and a diamond-shaped graph fans out the same way without ever repeating an
    # ancestor, which is why the bound is on WORK rather than on cycles. Past the budget the walk
    # stops, the list comes back short, and the client's count check refuses the colours — the safe
    # answer for a file shaped like nothing anyone printed. Sharing between branches stays legal:
    # a Bambu project names one part from several items, and each is its own mesh.
    def self.walk(zip, parts, path, object_id, item_object_id, depth, budget)
      return [] if depth > MAX_DEPTH
      return [] if (budget[:steps] -= 1).negative?

      object = objects_in(zip, parts, path)&.[](object_id.to_s)
      return [] if object.nil?
      return [ Leaf.new(item_object_id:, mesh_object_id: object_id.to_s, path:) ] if child(object, "mesh")

      components = child(object, "components")
      return [] if components.nil?

      elements(components, "component").flat_map do |component|
        walk(zip, parts, component_path(component) || path, component["objectid"], item_object_id, depth + 1, budget)
      end
    end

    # Parsed once per part file per manifest — a Bambu project names the same part from every one of
    # an object's components, and re-parsing a 6.8 MB document per component is the cost this memo
    # exists to avoid. A part file that is absent memoises nil so it is not looked up again.
    def self.objects_in(zip, parts, path)
      return parts[path] if parts.key?(path)

      root = xml(zip, path)
      parts[path] = root && root.name == "model" ? index_objects(root) : nil
    end

    def self.index_objects(root)
      resources = child(root, "resources")
      return {} if resources.nil?

      elements(resources, "object").each_with_object({}) do |object, map|
        map[object["id"].to_s] = object if object["id"].present?
      end
    end

    def self.component_path(component)
      raw = component.attribute_with_ns("path", PRODUCTION_NS)&.value || component["path"]
      return nil if raw.blank?

      raw.delete_prefix("/")
    end

    # --- reading the parts -------------------------------------------------------

    # STRICT, so a malformed document raises rather than being silently "recovered" into a tree with
    # the objects missing — which would answer a plausible, wrong colour list instead of nil.
    # `name` is the LOCAL name in Nokogiri, so nothing here depends on which core-namespace revision
    # a producer declared.
    def self.xml(zip, path)
      entry = zip.find_entry(path)
      return nil if entry.nil?

      Nokogiri::XML(entry.get_input_stream.read) { |config| config.strict }.root
    end

    def self.child(node, name) = node&.element_children&.find { |e| e.name == name }

    def self.elements(node, name) = node.element_children.select { |e| e.name == name }

    # DIRECT CHILDREN ONLY. A Bambu `<object>` holds both its own `<metadata key="extruder">` and
    # its parts' — a descendant search returns the first part's extruder for the object.
    def self.metadata_value(node, key)
      return nil if node.nil?

      elements(node, "metadata").find { |e| e["key"] == key }&.[]("value").presence
    end

    def self.child_by_id(node, name, id)
      return nil if node.nil?

      elements(node, name).find { |e| e["id"].to_s == id }
    end

    # A slicer's own config: `<config><object id="N">…</object>…</config>`, indexed by object id.
    def self.config_objects(zip, path)
      root = xml(zip, path)
      return {} if root.nil?

      elements(root, "object").each_with_object({}) do |object, map|
        map[object["id"].to_s] = object if object["id"].present?
      end
    end

    # AN EXTRUDER IS 1-BASED AND `0` MUST NOT BECOME A NEGATIVE INDEX. Bambu writes `extruder="0"`
    # on a part that inherits, and Ruby's `list[-1]` is the LAST filament — a real, plausible,
    # WRONG colour rather than no colour. Out of range is nil for the same reason.
    def self.nth_colour(list, number)
      return nil if number.blank?

      index = number.to_i - 1
      return nil if index.negative?

      normalize_hex(list[index])
    end

    # A slicer writes `#RRGGBB` or `#RRGGBBAA` — Bambu's project settings really do carry the alpha
    # (`#FFFFFFFF`), and a CSS colour with eight digits is not the colour the maker chose. Anything
    # else is dropped rather than guessed at.
    def self.normalize_hex(value)
      hex = value.to_s.strip.delete_prefix("#")
      return nil unless /\A\h{6}(\h{2})?\z/.match?(hex)

      "##{hex[0, 6].upcase}"
    end

    # --- the two slicers ---------------------------------------------------------

    # WHICH SLICER WROTE THIS, decided by the config file each one leaves behind. Neither is a
    # standard 3MF part, which is the whole reason this class exists.
    module Slicer
      def self.for(zip)
        return Bambu.new(zip) if zip.find_entry(Bambu::CONFIG)
        return Prusa.new(zip) if zip.find_entry(Prusa::CONFIG)

        nil
      end
    end

    # BAMBU STUDIO. `model_settings.config`'s `<object id>` is the ROOT container object a build
    # item names; its `<part id>` is the leaf object inside the referenced part file. A part's own
    # extruder wins over the object's — a real project uses exactly that to print one object's
    # lettering in a second filament.
    class Bambu
      CONFIG = "Metadata/model_settings.config".freeze
      SETTINGS = "Metadata/project_settings.config".freeze

      def initialize(zip)
        @objects = ThreeMfManifest.config_objects(zip, CONFIG)
        @filaments = filaments(zip)
      end

      def colors_for(leaves)
        leaves.map { |leaf| ThreeMfManifest.nth_colour(@filaments, extruder(leaf)) }
      end

      private

      # THE PART'S OWN EXTRUDER WINS WHERE IT IS WRITTEN AT ALL, including `extruder="0"`, which
      # Bambu writes on a modifier part and which `nth_colour` answers as NO colour. That is the
      # conservative reading: an override we do not understand leaves the engine's own material
      # standing rather than guessing at the object's.
      def extruder(leaf)
        object = @objects[leaf.item_object_id]
        return nil if object.nil?

        part = ThreeMfManifest.child_by_id(object, "part", leaf.mesh_object_id)
        ThreeMfManifest.metadata_value(part, "extruder") ||
          ThreeMfManifest.metadata_value(object, "extruder")
      end

      def filaments(zip)
        entry = zip.find_entry(SETTINGS)
        return [] if entry.nil?

        doc = JSON.parse(entry.get_input_stream.read)
        doc.is_a?(Hash) ? Array(doc["filament_colour"]) : []
      rescue JSON::ParserError
        []
      end
    end

    # PRUSASLICER. `Slic3r_PE_model.config` carries `<metadata type="object" key="extruder">` per
    # object; the palette is a `; extruder_colour = #A;#B` line in the plain-text `Slic3r_PE.config`.
    # A per-VOLUME extruder is deliberately not read — a Prusa volume is a triangle range of one
    # mesh, not a mesh of its own, so honouring it needs the per-triangle work this class excludes.
    class Prusa
      CONFIG = "Metadata/Slic3r_PE_model.config".freeze
      SETTINGS = "Metadata/Slic3r_PE.config".freeze
      # TWO KEYS, IN THIS ORDER, AND THE SECOND IS NOT REDUNDANT. `extruder_colour` is the PRINTER
      # profile's per-extruder colour and is blank in most real projects; `filament_colour` is the
      # loaded filament's, and is the one a maker actually set. Falling back per SLOT rather than
      # per file, because a project may colour extruder 1 in the printer profile and leave 2 to its
      # filament. (Neither is checked against a real PrusaSlicer export — the library holds none;
      # both arms are covered by the fixture instead, and that limit is stated in the PR.)
      COLOUR_KEYS = %w[extruder_colour filament_colour].freeze

      def initialize(zip)
        @objects = ThreeMfManifest.config_objects(zip, CONFIG)
        @colours = extruder_colours(zip)
      end

      def colors_for(leaves)
        leaves.map do |leaf|
          object = @objects[leaf.item_object_id]
          ThreeMfManifest.nth_colour(@colours, object && ThreeMfManifest.metadata_value(object, "extruder"))
        end
      end

      private

      def extruder_colours(zip)
        entry = zip.find_entry(SETTINGS)
        return [] if entry.nil?

        text = entry.get_input_stream.read
        lists = COLOUR_KEYS.map { |key| colour_list(text, key) }
        Array.new(lists.map(&:size).max.to_i) { |i| lists.filter_map { |list| list[i] }.first }
      end

      # SPLIT WITH -1 so a trailing blank keeps its slot: `#FF0000;;#0000FF` is extruder 2 having no
      # colour, not extruder 3 shifting down into its place.
      def colour_list(text, key)
        pattern = /^;\s*#{key}\s*=\s*(.*)$/
        line = text.each_line.find { |l| pattern.match?(l) }
        return [] if line.nil?

        line[pattern, 1].to_s.split(";", -1).map { |c| c.strip.presence }
      end
    end
  end
end
