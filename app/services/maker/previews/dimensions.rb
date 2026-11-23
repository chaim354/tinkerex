module Maker
  module Previews
    # A FLAT FILE'S SIZE, IN MILLIMETRES — THE ONE MEASURER AND THE ONE READER (2026-11-22; spec
    # docs/superpowers/specs/2026-11-22-material-estimate-design.md).
    #
    # Four formats measure: SVG, LightBurn, DXF and MillMage. Each already has a traversal that
    # draws and measures it (§14h), and THIS MODULE ADDS NO FIFTH READING of any of them: an SVG's
    # size is its Measure payload's job box (`SvgGeometry.build`), a DXF's is the box its thumbnail's
    # own walk draws (`Dxf.drawing`), and LightBurn's and MillMage's are what their metadata modules
    # already store (`Lbrn2.page_metadata`). So the facts list, the Measure view and the Material
    # estimate tool cannot disagree about one file. A second parser here would be §14b's
    # `LbrnMetadata` second-copy bug.
    #
    # THE HASH IS THE STORED SHAPE. `measure` returns exactly what a thumbnail row's `metadata` holds
    # for a size — `"job" => {"width", "height"}` in mm and, for a multi-page file, `"pages"` — so the
    # tool reads an upload it just measured and a library file's stored row through ONE
    # `from_metadata`.
    #
    # IT IS THE EXTENT OF WHAT IS DRAWN, never an SVG's width/height canvas: a design exported on an
    # A4 page measures as the design, which is what LightBurn's own job size has always meant.
    module Dimensions
      module_function

      EXTENSIONS = %w[svg dxf lbrn lbrn2 mage].freeze

      # The keys a size occupies in a thumbnail's metadata. Metadata holding nothing else is a size
      # and not a recipe, so it draws no Laser or CNC settings panel — see `recipe?`.
      SIZE_KEYS = %w[job pages].freeze

      MM_PER_INCH = 25.4

      UNSUPPORTED = "not an SVG, LightBurn, DXF or MillMage file".freeze
      NO_SHAPES = "no measurable shapes".freeze

      # Raised by `measure` with a reason a person can read; the tool shows it beside the file.
      Unmeasurable = Class.new(StandardError)

      # One page of a file, mm. `name` is nil for a one-page file; `width`/`height` are nil for an
      # empty page of a multi-page one.
      Page = Data.define(:name, :width, :height, :current) do
        def sized? = !width.nil?
      end

      Facts = Data.define(:pages) do
        def multi_page? = pages.length > 1
        def sized_pages = pages.select(&:sized?)
      end

      def extension(name) = File.extname(name.to_s).delete_prefix(".").downcase

      def measurable_name?(name) = EXTENSIONS.include?(extension(name))

      # bytes -> the stored Hash. Raises Unmeasurable; anything else a parser raises propagates,
      # which the tool's caller (Maker::Material::Sources) turns into a reason of its own.
      def measure(name, bytes) = measure_ext(extension(name), bytes)

      # FOR A THUMBNAIL RENDER: the same Hash, or nil, and NEVER a raise. A size is a fact beside the
      # picture, so a drawing this module cannot measure must not cost the file its thumbnail.
      def metadata_for(bytes, ext:)
        measure_ext(ext, bytes)
      rescue StandardError => e
        Rails.logger.warn("dimensions: .#{ext}: #{e.class}: #{e.message}") unless e.is_a?(Unmeasurable)
        nil
      end

      # A size the caller already holds (`{"width", "height"}`, mm), in the stored shape — or nil for
      # an empty drawing. The DXF thumbnail's walk measures as it draws and hands its box here.
      def job_metadata(size)
        hash = { "job" => size }
        from_metadata(hash) ? hash : nil
      end

      # A stored (or just-measured) Hash -> Facts, or nil when it holds no usable size.
      def from_metadata(metadata)
        return nil unless metadata.is_a?(Hash)

        pages = listed_pages(metadata["pages"]) || [ page(nil, metadata["job"], true) ]
        pages.any?(&:sized?) ? Facts.new(pages:) : nil
      end

      def recipe?(metadata) = metadata.is_a?(Hash) && (metadata.keys.map(&:to_s) - SIZE_KEYS).any?

      def measure_ext(ext, bytes)
        hash = read_sizes(ext, bytes)
        raise Unmeasurable, NO_SHAPES if from_metadata(hash).nil?

        hash
      end

      def read_sizes(ext, bytes)
        case ext
        when "svg" then svg(bytes)
        when "dxf" then job_metadata(Maker::Previews::Dxf.drawing(bytes).last)
        when "lbrn", "lbrn2" then recipe_sizes(Maker::Previews::LbrnMetadata.parse(bytes), "LightBurn")
        when "mage" then recipe_sizes(Maker::Previews::MageMetadata.parse(bytes), "MillMage")
        else raise Unmeasurable, UNSUPPORTED
        end
      end

      # A multi-page file's pages, or nil for a one-page file (whose metadata carries no "pages").
      def listed_pages(listed)
        return nil unless listed.is_a?(Array) && listed.any?

        listed.filter_map { |pg| page(pg["name"], pg["job"], pg["current"] == true) if pg.is_a?(Hash) }
      end

      # The Measure payload's own job box, so the facts row and the Measure view read one number.
      def svg(bytes)
        job = Maker::Previews::SvgGeometry.build(bytes)["job"]
        { "job" => { "width" => job["w"], "height" => job["h"] } }
      rescue Maker::Previews::SvgGeometry::ParseError
        raise Unmeasurable, "not a readable SVG"
      end

      # LbrnMetadata/MageMetadata answer nil for a file that is not theirs (they rescue internally).
      def recipe_sizes(metadata, app)
        raise Unmeasurable, "not a readable #{app} file" if metadata.nil?

        metadata.slice(*SIZE_KEYS)
      end

      def page(name, job, current)
        width, height = size(job)
        Page.new(name: name.to_s.presence, width:, height:, current:)
      end

      # [width, height] in mm, or [nil, nil] for anything that is not two finite, non-negative
      # numbers with at least one above zero. A 0 x 0 box is an empty drawing, never a part.
      def size(job)
        return [ nil, nil ] unless job.is_a?(Hash)

        w = mm(job["width"])
        h = mm(job["height"])
        w && h && (w.positive? || h.positive?) ? [ w, h ] : [ nil, nil ]
      end

      def mm(value)
        f = Float(value, exception: false)
        f if f&.finite? && !f.negative?
      end
    end
  end
end
