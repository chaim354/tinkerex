module Maker
  # THE ONE GRAMMAR OF A PAGE LAYOUT (2026-09-09, the page editor; spec §4 and decision 2). Three
  # forms of one thing meet here and nowhere else: the DRAFT the browser holds (keys), the YAML a
  # maker copies and pastes (folder NAMES, never node ids), and the six-map COLUMN the layout
  # reads back. The browser never parses or emits YAML; it posts a draft and receives text, or
  # posts text and receives a draft with notes and errors.
  #
  # APPLY MERGES, IT DOES NOT REPLACE (spec decision 3): listed entries take the order and the
  # attributes given, an attribute not given keeps the draft's current value, and the panels of
  # this project the text does not mention keep their settings and follow in their current
  # relative order — so a layout shared from a smaller project hides nothing here.
  #
  # ERRORS BLOCK, NOTES INFORM, AND A MISSPELLING IS AN ERROR (decision 5): the format is typed by
  # hand, and a silently ignored `hiden: true` is how a hand-typed line does nothing for a week.
  #
  # AN ENTRY IS A PANEL, A FOLDER OR A BLOCK (2026-09-09, content blocks; spec §5), and the third
  # is the one that carries CONTENT rather than only an arrangement: a block entry holds the text,
  # the link or the picture itself, so the draft and the YAML are the whole of what Save writes. In
  # the YAML the discriminator is exactly one of `panel:`, `folder:` and `block:`; a saved block
  # also carries `id:` (Maker::ProjectBlock#key, never a row id), which is what lets a pasted
  # layout UPDATE the block it came from while an unknown id CREATES one — a layout pasted from
  # another project brings its blocks with it rather than renaming this project's.
  #
  # A TAB IS THE FOURTH KIND OF ENTRY (2026-09-09, tabs; spec §4), and the lightest: `- tab: Build`
  # with an `id:` in the YAML, `{ key, kind: "tab", name }` in the draft, nothing else on either.
  # Apply resolves a tab by id, then by NAME ignoring case, then creates one — a tab's name is its
  # identity to a person, so a layout pasted from another project maps Build onto Build rather than
  # making a second one (decision 4). A tab has no width, hidden, view or intro; a tab entry naming
  # one is an error, not a note. `kind` NO LONGER MEANS "a block": every reader of it here asks for
  # a block kind by name (#blocks_from, the block cap) so a separator is never written as a row.
  #
  # A `page` MAPPING sits beside `panels`: the project's description and its cover. A cover and an
  # image block name a node id in the draft and a PATH UNDER THE PROJECT FOLDER in the YAML, which
  # is the same rule folders follow (`images:`, the map the caller supplies) — a node id is not
  # shareable and means nothing in another project.
  #
  # THREE OUTPUTS FEED SAVE, one door each: #column (the six maps the layout reads back), #blocks_from
  # (a row's worth of attributes per block) and #page_from (the description and the cover node id).
  #
  # PURE: takes a Layout, a { node_id => name } map, the block ROWS (read, never written) and a
  # { node_id => path } map, touches no row and no port, so every rule runs identically on the
  # three backend legs. Psych's `safe_load` with no permitted classes and a 16 KB cap is the whole
  # of the parsing surface.
  class LayoutDocument
    VERSION = 1
    MAX_BYTES = 16 * 1024
    ATTRIBUTES = %w[title intro width view hidden].freeze
    # A BLOCK TAKES THE ARRANGEMENT ATTRIBUTES AND ITS OWN KIND'S FIELDS, AND NOTHING ELSE: `title`
    # on a link is the link's label, `view` on a block is an error, and the two sets are separate
    # so a misspelling inside a block is still caught by name (spec decision 5).
    BLOCK_COMMON = %w[width hidden].freeze
    BLOCK_FIELDS = { "text" => %w[heading body], "link" => %w[url title line], "image" => %w[file caption] }.freeze
    PAGE_KEYS = %w[description cover].freeze
    COVER_OUTSIDE_NOTE = "# cover: set from a file outside the project folder; the picker cannot name it".freeze
    IMAGE_OUTSIDE_NOTE = "# image block %s: its picture is outside the project folder or gone; left out of this text".freeze

    Result = Data.define(:draft, :notes, :errors) do
      def ok? = errors.empty?
    end

    # blocks: the project's Maker::ProjectBlock rows (anything answering key/kind/heading/body/url/
    # line/caption/node_id); images: { node_id => path relative to the project folder } for the
    # folder's image files — what an image block or the cover may name; page: the description and
    # the cover node id as the row holds them.
    def initialize(layout, folder_names, blocks: [], images: {}, page: {})
      @layout = layout
      @names = folder_names.to_h { |id, name| [ id.to_s, name.to_s ] }
      @blocks = blocks.to_h { |b| [ Maker::ProjectKind.block_key(b.key), b ] }
      @images = images.to_h { |id, path| [ id.to_s, path.to_s ] }
      @paths = @images.invert
      @page = { "description" => page["description"].presence, "cover" => page["cover"].presence }
    end

    # --- the draft ---------------------------------------------------------------------------

    def draft
      { "layout" => VERSION, "page" => @page.dup, "panels" => @layout.order.map { |key| entry(key) } }
    end

    # --- export ------------------------------------------------------------------------------

    def to_yaml(draft = self.draft, project_name:)
      dropped = []
      panels = draft["panels"].filter_map do |e|
        out = {}
        # A SEPARATOR IN PLACE, TWO LINES AND NO MORE (2026-09-09, tabs; spec §4): `next out` leaves
        # before the width/view/hidden tail below, which a tab has none of.
        if e["kind"] == "tab"
          out["tab"] = e["name"]
          out["id"] = e["key"].delete_prefix(Maker::ProjectKind::TAB_PREFIX) unless new_key?(e["key"])
          next out
        end
        if e["kind"]
          out["block"] = e["kind"]
          # A `new-` KEY CARRIES NO `id:`: it names nothing outside this browser session, and a
          # pasted `id: new-1` would read as an unknown id and create a second block.
          out["id"] = e["key"].delete_prefix(Maker::ProjectKind::BLOCK_PREFIX) unless new_key?(e["key"])
          case e["kind"]
          when "text"
            out["heading"] = e["heading"] if e["heading"]
            out["body"] = e["body"] if e["body"]
          when "link"
            # GUARDED LIKE THE OTHER TWO ARMS (found in review): a row gone between two reads leaves
            # a kind-less entry with no url, and a bare `url:` null re-applies as an error.
            out["url"] = e["url"] if e["url"]
            out["title"] = e["title"] if e["title"]
            out["line"] = e["line"] if e["line"]
          when "image"
            # TOTAL like the folder branch below: an image whose file has left the project folder
            # has no shareable name, so it is left out of the text rather than exported as a node
            # id another project could not resolve — and SAID in the header, like the cover, because
            # a silent drop re-applied to this same page moved the block to the end (found in review).
            path = @images[e["file"].to_s]
            unless path
              dropped << e["key"]
              next
            end

            out["file"] = path
            out["caption"] = e["caption"] if e["caption"]
          end
        elsif @layout.folder?(e["key"])
          # TOTAL, LIKE #label BELOW (found in review): a folder key with no name — the layout and
          # the names built from two different reads, a folder gone between them — is left out of
          # the text rather than a KeyError on every editor render. The layout's own totality
          # argument (its header), applied to the export.
          name = @names[@layout.folder_id(e["key"])]
          next unless name

          out["folder"] = name
        else
          out["panel"] = e["key"]
        end
        unless e["kind"]
          out["title"] = e["title"] if e["title"]
          out["intro"] = e["intro"] if e["intro"]
        end
        out["width"] = e["width"]
        out["view"] = e["view"] if e["view"]
        out["hidden"] = true if e["hidden"]
        out
      end
      page = {}
      page["description"] = draft.dig("page", "description") if draft.dig("page", "description").present?
      cover = draft.dig("page", "cover")
      cover_path = cover && @images[cover.to_s]
      page["cover"] = cover_path if cover_path
      doc = { "layout" => VERSION }
      doc["page"] = page if page.any?
      doc["panels"] = panels
      body = Psych.dump(doc, line_width: -1).delete_prefix("---\n")
      header = "# #{project_name.to_s.gsub(/\s+/, ' ').strip}, page layout. Paste into another project's editor to reuse it.\n"
      # A COVER THE PICKER CANNOT NAME IS SAID OUT LOUD RATHER THAN DROPPED SILENTLY: the file is
      # outside the project folder (a hero chosen before the folder moved), so there is no path to
      # write, and a reader who pastes this text elsewhere should know why their cover did not come.
      header += "#{COVER_OUTSIDE_NOTE}\n" if cover && !cover_path
      dropped.each do |key|
        header += format(IMAGE_OUTSIDE_NOTE, new_key?(key) ? "new" : key.delete_prefix(Maker::ProjectKind::BLOCK_PREFIX)) + "\n"
      end
      header + body
    end

    # --- parse: YAML text in ---------------------------------------------------------------------

    # `base:` IS THE BROWSER'S DRAFT when Apply supplies one — already validated through #from_draft
    # by the caller — so a hide made with the eye a moment ago survives an Apply whose text does not
    # name that panel. nil means the saved layout (the browser suite found the difference).
    def parse(text, base: nil)
      text = text.to_s
      return failure("The layout is over #{MAX_BYTES / 1024} KB.") if text.bytesize > MAX_BYTES

      data = begin
        Psych.safe_load(text, permitted_classes: [], aliases: false)
      rescue Psych::Exception, Psych::SyntaxError => e
        line = e.respond_to?(:line) ? e.line : nil
        column = e.respond_to?(:column) ? e.column : nil
        problem = e.respond_to?(:problem) ? e.problem : e.message
        return failure(line ? "Line #{line}, column #{column}: #{problem}." : "The YAML did not parse: #{problem}.")
      end
      return failure("The layout must be a mapping with `layout` and `panels`.") unless data.is_a?(Hash)

      version = data["layout"]
      # `Numeric`, not `Integer`: `layout: 2.0` is a newer document too, and the honest message is
      # "newer than this server", not "`layout: 1` is required" (found in review).
      if version.is_a?(Numeric) && version > VERSION
        return failure("`layout: #{version}` is newer than this server, which reads version #{VERSION}.")
      end
      return failure("`layout: #{VERSION}` is required at the top.") unless version == VERSION

      unknown = data.keys.map(&:to_s) - %w[layout page panels]
      return failure("Unknown key “#{unknown.first}” at the top level.") if unknown.any?
      return failure("`panels` must be a list.") unless data["panels"].is_a?(Array)
      if data.key?("page") && !data["page"].is_a?(Hash)
        return failure("`page` must be a mapping with `description` and `cover`.")
      end

      merge(data["panels"], :yaml, base, page: data["page"])
    end

    # --- from_draft: the browser's JSON in ----------------------------------------------------------

    def from_draft(hash)
      return failure("Not a layout draft.") unless hash.is_a?(Hash) && hash["panels"].is_a?(Array)
      return failure("Not a layout draft.") if hash.key?("page") && !hash["page"].is_a?(Hash)

      merge(hash["panels"], :draft, nil, page: hash["page"])
    end

    # --- the column -------------------------------------------------------------------------------

    def column(draft)
      panels = draft["panels"]
      # A BLOCK'S OWN CONTENT IS NOT A PANEL OVERRIDE (2026-09-09, content blocks): a link entry
      # carries `title`, which is the LINK'S LABEL and belongs in its row, so the three sparse text
      # maps are built from the entries that are not blocks. `order`, `hidden` and `widths` DO carry
      # block keys — those are the arrangement, which is exactly what this column holds.
      arranged = panels.reject { |e| e["kind"] }
      # A TAB IS IN `order` AND `titles` AND NOWHERE ELSE (2026-09-09, tabs; spec §3): its name is a
      # title, its key has no width, no view, no intro and no hidden flag.
      tabs = panels.select { |e| e["kind"] == "tab" }
      sized = panels.reject { |e| e["kind"] == "tab" }
      { "order" => panels.map { |e| e["key"] },
        "hidden" => sized.select { |e| e["hidden"] }.map { |e| e["key"] },
        "views" => arranged.filter_map { |e| [ e["key"], e["view"] ] if e["view"] }.to_h,
        # WIDTHS ARE WRITTEN FOR EVERY PANEL, DEFAULTS INCLUDED, BY DESIGN: a Save records the
        # arrangement the maker saw and approved, and the width is a control they operated. A folder
        # added later still falls through to default_width (Layout#width_for is `||`), so this is
        # additive, not the freezing bug the retired chooser's move branch had. Titles stay sparse
        # for the opposite reason: a maker never chose a default label, so a PANEL_LABELS change
        # must still reach a saved project. Do not "tidy" this into a filter on non-defaults.
        "widths" => sized.to_h { |e| [ e["key"], e["width"] ] },
        "titles" => arranged.filter_map { |e| [ e["key"], e["title"] ] if e["title"] }.to_h.merge(tabs.to_h { |e| [ e["key"], e["name"] ] }),
        "intros" => arranged.filter_map { |e| [ e["key"], e["intro"] ] if e["intro"] }.to_h }
    end

    # --- what Save writes beside the column -------------------------------------------------------

    # One hash per block IN THE DRAFT'S ORDER, keyed as the draft keys it (`block:<key>` or
    # `block:new-<n>`) — Save mints the real key for a `new-` one. EVERY FIELD IS PRESENT, nil
    # included, so an attribute cleared in the editor is written as a clear rather than left behind.
    def blocks_from(draft)
      draft["panels"].select { |e| Maker::ProjectBlock::KINDS.include?(e["kind"]) }.map do |e|
        { "key" => e["key"], "kind" => e["kind"],
          # A LINK'S `title` IS THE ROW'S `heading`: one column, so a kind change keeps its label.
          "heading" => e["kind"] == "link" ? e["title"] : e["heading"],
          "body" => e["body"], "url" => e["url"], "line" => e["line"], "caption" => e["caption"], "node_id" => e["file"] }
      end
    end

    # nil MEANS "THIS DOCUMENT SAYS NOTHING ABOUT THE PAGE", which is not the same as a page with a
    # blank description: a draft posted by an older browser has no `page`, and Save must leave the
    # project's own description alone rather than clearing it.
    def page_from(draft)
      return nil unless draft["page"].is_a?(Hash)

      { "description" => draft["page"]["description"].presence, "cover_node_id" => draft["page"]["cover"].presence }
    end

    private

    def entry(key)
      return { "key" => key, "kind" => "tab", "name" => @layout.tab_name_for(key) } if @layout.tab?(key)

      e = { "key" => key, "hidden" => @layout.hidden?(key), "width" => @layout.width_for(key) }
      if @layout.block?(key)
        # THE ROW IS THE CONTENT'S ONE SOURCE: the layout column holds a block's PLACE, never its
        # text. `&.` throughout because the layout and the rows are two reads — a block deleted
        # between them leaves a key with no row, which renders as an empty entry rather than a 500.
        row = @blocks[key]
        e["kind"] = @layout.block_kind(key)
        case e["kind"]
        when "text"
          e["heading"] = row.heading if row&.heading.present?
          e["body"] = row.body if row&.body.present?
        when "link"
          e["url"] = row&.url
          e["title"] = row&.heading
          e["line"] = row.line if row&.line.present?
        when "image"
          e["file"] = row&.node_id
          e["caption"] = row.caption if row&.caption.present?
        end
        return e.compact
      end
      e["view"] = @layout.view_for(key) if Maker::ProjectKind.offered_views(key).any?
      e["title"] = @layout.titles[key] if @layout.titles[key]
      e["intro"] = @layout.intros[key] if @layout.intros[key]
      e
    end

    def failure(message) = Result.new(draft: draft, notes: [], errors: [ message ])

    # The merge, shared by both doors. `source` says how an entry names its panel: `:yaml` by
    # `panel:`/`folder:` (names), `:draft` by `key`. Everything after the key is one code path.
    def merge(raw_entries, source, base = nil, page: nil)
      notes, errors = [], []
      base_draft = base || draft
      current = base_draft["panels"].to_h { |e| [ e["key"], e ] }
      listed = []
      # THE NEW-KEY COUNTER STARTS ABOVE THE BASE DRAFT'S OWN `new-` KEYS: a block added with the
      # button a moment ago is `block:new-1` and is not in the text being applied, so allocating
      # from 1 again would hand a pasted block the unsaved one's key and merge the two.
      next_new = next_new_index(current.keys)

      raw_entries.each_with_index do |raw, i|
        n = i + 1
        unless raw.is_a?(Hash)
          errors << "Entry #{n} is not a mapping."
          next
        end
        raw = raw.to_h { |k, v| [ k.to_s, v ] }
        key, kind = source == :yaml ? key_from_yaml(raw, n, notes, errors, current, -> { next_new += 1 }) : key_from_draft(raw, n, notes, errors)
        next unless key

        # THE ATTRIBUTE CHECK COMES BEFORE THE DUPLICATE GUARD, as it did in slice 1: an entry that
        # is both a repeat and misspelled reports both, not one reason per round trip (found in
        # review — the block branch had put it after the `next`).
        # A TAB'S CHECK IS ITS OWN because its answer is: `BLOCK_FIELDS.fetch("tab")` would raise,
        # and "unknown attribute “hidden”" is the wrong sentence for an attribute that exists
        # everywhere else and is refused only here (2026-09-09, tabs; spec §7).
        if kind == "tab"
          unknown = raw.keys - (source == :yaml ? %w[tab id] : %w[key kind name])
          errors << "Entry #{n}: a tab takes only a name (“#{unknown.first}” is not allowed)." if unknown.any?
        else
          allowed = if kind
            (source == :yaml ? %w[block id] : %w[key kind]) + BLOCK_COMMON + BLOCK_FIELDS.fetch(kind)
          else
            (source == :yaml ? %w[panel folder] : %w[key]) + ATTRIBUTES
          end
          unknown = raw.keys - allowed
          errors << "Entry #{n}: unknown attribute “#{unknown.first}”." if unknown.any?
        end
        if listed.any? { |k, _| k == key }
          errors << "Entry #{n} names #{label(key)} a second time."
          next
        end
        if kind == "tab"
          base_entry = current[key] || { "key" => key, "kind" => "tab", "name" => nil }
          listed << [ key, apply_tab(base_entry, raw, source, n, errors) ]
        else
          base_entry = current[key] || { "key" => key, "kind" => kind, "hidden" => false, "width" => Maker::ProjectKind.default_width(key, block_kind: kind) }
          if kind
            listed << [ key, apply_block(base_entry, raw, kind, n, notes, errors, new_block: current[key].nil?) ]
          else
            listed << [ key, apply(base_entry, raw, key, n, notes, errors) ]
          end
        end
      end
      page_out = merge_page(base_draft["page"], page, notes, errors)
      return Result.new(draft: draft, notes: notes, errors: errors) if errors.any?

      ordered = listed.map(&:last) + (current.keys - listed.map(&:first)).map { |k| current[k] }
      if listed.any? { |k, _| k == "publish" } && ordered.last["key"] != "publish"
        publish = ordered.find { |e| e["key"] == "publish" }
        ordered = (ordered - [ publish ]) + [ publish ]
        notes << "Publish is always last; it was moved to the end."
      end
      # THE CAP IS COUNTED ON THE RESULT, NOT ON WHAT THE TEXT LISTS: the blocks the text does not
      # mention keep their place, so a paste of forty into a project that already holds three is
      # forty-three blocks. An error, never a truncation — which of them to drop is not ours to pick.
      # A BLOCK IS ASKED FOR BY KIND (2026-09-09, tabs; sharpened in review): a separator carries a
      # `kind` too, so counting every kinded entry would let eight tabs eat eight of the forty block
      # slots — and an exclusion (`!= "tab"`) would leak the NEXT entry kind the same way.
      if ordered.count { |e| Maker::ProjectBlock::KINDS.include?(e["kind"]) } > Maker::ProjectBlock::CAP
        return Result.new(draft: draft, notes: notes, errors: [ "That would leave more than #{Maker::ProjectBlock::CAP} blocks on the page." ])
      end
      # TWO CHECKS ON THE RESULT, NOT THE TEXT, for the block cap's reason: the tabs the text does not
      # mention keep their place. Names are compared ignoring case because the slug and the match
      # by name both do (spec §3, §4).
      tabs = ordered.select { |e| e["kind"] == "tab" }
      if (dup = tabs.map { |e| e["name"].to_s.downcase }.tally.find { |_, c| c > 1 })
        # THE NAME AS THE MAKER WROTE IT, not the downcased key the tally grouped on (found in review).
        as_written = tabs.find { |e| e["name"].to_s.downcase == dup.first }["name"]
        return Result.new(draft: draft, notes: notes, errors: [ "Two tabs are named “#{as_written}”; tab names must differ." ])
      end
      if tabs.size > Maker::ProjectKind::TAB_CAP
        return Result.new(draft: draft, notes: notes, errors: [ "This page can hold #{Maker::ProjectKind::TAB_CAP} tabs; this would leave #{tabs.size}." ])
      end
      Result.new(draft: { "layout" => VERSION, "page" => page_out, "panels" => ordered }, notes: notes, errors: errors)
    end

    # `[key, kind]`, with `kind` nil for a panel or a folder — the one place a block entry is told
    # apart from an arrangement entry, so everything after it is one code path.
    def key_from_yaml(raw, n, notes, errors, current, allocate)
      named = %w[panel folder block tab].select { |k| raw.key?(k) }
      if named.size > 1
        errors << "Entry #{n} names more than one of `panel`, `folder`, `block` and `tab`; use one."
        return nil
      end
      if raw.key?("tab")
        # BY ID, THEN BY NAME, THEN NEW (spec §4, decision 4). `current` is the base draft, so a tab
        # added with the button a moment ago is matchable by name too.
        id = raw["id"].to_s
        return [ Maker::ProjectKind.tab_key(id), "tab" ] if id.present? && current[Maker::ProjectKind.tab_key(id)]&.dig("kind") == "tab"

        name = text(raw["tab"])
        twin = name.empty? ? nil : current.values.find { |e| e["kind"] == "tab" && e["name"].to_s.casecmp?(name) }
        return [ twin["key"], "tab" ] if twin

        return [ Maker::ProjectKind.tab_key("new-#{allocate.call}"), "tab" ]
      end
      if raw.key?("block")
        kind = raw["block"].to_s
        unless Maker::ProjectBlock::KINDS.include?(kind)
          errors << "Entry #{n}: unknown block kind “#{kind}”."
          return nil
        end
        # AN ID THIS PROJECT KNOWS UPDATES; ANYTHING ELSE CREATES (spec §5). The kind has to match
        # too: `id: <a text block>` under `block: link` is a layout pasted from elsewhere whose id
        # happens to collide, and updating across kinds would rewrite an unrelated block.
        id = raw["id"].to_s
        known = id.present? && current.key?(Maker::ProjectKind.block_key(id)) && current[Maker::ProjectKind.block_key(id)]["kind"] == kind
        return [ known ? Maker::ProjectKind.block_key(id) : Maker::ProjectKind.block_key("new-#{allocate.call}"), kind ]
      end
      if raw.key?("panel")
        key = raw["panel"].to_s
        return [ key, nil ] if Maker::Project::PANELS.include?(key)

        errors << "Entry #{n}: unknown panel “#{key}”."
        return nil
      end
      if raw.key?("folder")
        name = raw["folder"].to_s
        id = @names.key(name)
        return [ Maker::ProjectKind.folder_key(id), nil ] if id && @layout.order.include?(Maker::ProjectKind.folder_key(id))

        notes << "This project has no folder named “#{name}”; that entry was skipped."
        return nil
      end
      errors << "Entry #{n} names none of `panel`, `folder`, `block` or `tab`."
      nil
    end

    def key_from_draft(raw, n, notes, errors)
      key = raw["key"].to_s
      if @layout.tab?(key)
        # A `new-` KEY IS THE BROWSER'S OWN; ANY OTHER TAB KEY MUST BE ONE OF THIS LAYOUT'S — the
        # same rule a block key follows, so a posted `tab:<invented>` is refused, not created.
        return [ key, "tab" ] if raw["kind"].to_s == "tab" && (new_key?(key) || @layout.order.include?(key))

        errors << "Entry #{n}: unknown tab “#{key}”."
        return nil
      end
      if @layout.block?(key)
        kind = raw["kind"].to_s
        unless Maker::ProjectBlock::KINDS.include?(kind)
          errors << "Entry #{n}: unknown block kind “#{kind}”."
          return nil
        end
        # A `new-` KEY IS THE BROWSER'S OWN AND HAS NO ROW YET; ANY OTHER BLOCK KEY MUST BE A BLOCK
        # OF THIS PROJECT, of this kind — a posted `block:<someone else's key>` is refused rather
        # than created, so the draft can never name a row the layout does not know.
        return [ key, kind ] if new_key?(key) || @layout.block_kind(key) == kind

        errors << "Entry #{n}: unknown block “#{key}”."
        return nil
      end
      return [ key, nil ] if @layout.order.include?(key)

      if @layout.folder?(key)
        # A FOLDER RENAMED ON DISK MID-EDIT (share/s3 mint a new dir id on rename — the layout's
        # own header): the key left the vocabulary between the page render and this Save.
        notes << "A folder changed on disk while you were editing; its panel keeps its defaults."
      else
        errors << "Entry #{n}: unknown panel “#{key}”."
      end
      nil
    end

    # A key the BROWSER minted for a block or a tab that Save has not keyed yet — ONE COUNTER OVER
    # BOTH PREFIXES (2026-09-09, tabs), so a session that adds a block and then a tab gets
    # `block:new-1` and `tab:new-2` rather than two entries both allocating 1 and a paste merging
    # them. Save turns each into a real key.
    NEW_KEY = /\A(?:block|tab):new-(\d+)\z/
    def new_key?(key) = key.to_s.match?(/\A(?:block|tab):new-/)
    def next_new_index(keys) = keys.filter_map { |k| k[NEW_KEY, 1]&.to_i }.max || 0

    # An attribute GIVEN replaces; one absent keeps `base`'s value. A given blank title or intro
    # clears it. `hidden: true` on an always-shown panel is a note, never an error, because a
    # shared layout may reasonably carry it.
    def apply(base, raw, key, n, notes, errors)
      e = base.dup
      if raw.key?("title")
        title = text(raw["title"])
        errors << "Entry #{n}: the title is over #{Maker::ProjectKind::TITLE_MAX} characters." if title.length > Maker::ProjectKind::TITLE_MAX
        if title.empty?
          e.delete("title")
        else
          e["title"] = title
        end
      end
      if raw.key?("intro")
        intro = text(raw["intro"])
        errors << "Entry #{n}: the intro is over #{Maker::ProjectKind::INTRO_MAX} characters." if intro.length > Maker::ProjectKind::INTRO_MAX
        if intro.empty?
          e.delete("intro")
        else
          e["intro"] = intro
        end
      end
      if raw.key?("width")
        width = raw["width"].to_s
        if Maker::ProjectKind::WIDTHS.include?(width)
          e["width"] = width
        else
          errors << "Entry #{n}: width must be full or half."
        end
      end
      # A nil `view` IS SKIPPED, NOT AN ERROR, because a browser draft may carry `"view": null` (ours
      # omits the key — layout_editor_controller.js's `entry` — but the tolerance costs nothing)
      # for a panel that offers none. The cost, accepted: a hand-typed bare `view:` with no value
      # does nothing, silently — the one blank this grammar lets through, where every misspelling
      # is an error.
      if raw.key?("view") && !raw["view"].nil?
        view = raw["view"].to_s
        offered = Maker::ProjectKind.offered_views(key)
        if offered.empty?
          errors << "Entry #{n}: #{label(key)} has no view."
        elsif offered.include?(view)
          e["view"] = view
        else
          errors << "Entry #{n}: #{label(key)} does not offer the #{view} view."
        end
      end
      if raw.key?("hidden")
        hidden = raw["hidden"]
        if [ true, false ].include?(hidden)
          if hidden && Maker::ProjectKind::ALWAYS.include?(key)
            notes << "#{label(key)} is always shown; `hidden` was ignored."
            e["hidden"] = false
          else
            e["hidden"] = hidden
          end
        else
          errors << "Entry #{n}: hidden must be true or false."
        end
      end
      e
    end

    # A BLOCK'S ATTRIBUTES, THE SAME MERGE RULE AS #apply: given replaces, absent keeps, blank
    # clears. `new_block:` is the one thing that reads differently — a file this folder does not
    # hold is an ERROR for a block being created (it would have no picture at all) and a NOTE for
    # one that already has one (it keeps it), which is spec §5's rule 3.
    #
    # THE FIELDS ARE CHECKED HERE AND AGAIN IN Maker::ProjectBlock: this is the door's answer, in
    # the entry's own words ("Entry 3: a link needs a title"), and the model is the lock no door
    # can bypass. Neither is redundant.
    def apply_block(base, raw, kind, n, notes, errors, new_block:)
      e = base.dup
      e["kind"] = kind
      if raw.key?("width")
        width = raw["width"].to_s
        if Maker::ProjectKind::WIDTHS.include?(width)
          e["width"] = width
        else
          errors << "Entry #{n}: width must be full or half."
        end
      end
      if raw.key?("hidden")
        if [ true, false ].include?(raw["hidden"])
          e["hidden"] = raw["hidden"]
        else
          errors << "Entry #{n}: hidden must be true or false."
        end
      end
      case kind
      when "text"
        set_text(e, raw, "heading", Maker::ProjectBlock::HEADING_MAX, n, errors, "the heading")
        if raw.key?("body")
          # STRIPPED, NEVER COLLAPSED, unlike every other text here: the body is Markdown and its
          # blank lines are what separate its paragraphs.
          body = raw["body"].to_s.strip
          errors << "Entry #{n}: the body is over #{Maker::ProjectBlock::BODY_MAX / 1024} KB." if body.bytesize > Maker::ProjectBlock::BODY_MAX
          body.empty? ? e.delete("body") : e["body"] = body
        end
        errors << "Entry #{n}: a text block needs a heading or a body." if e["heading"].blank? && e["body"].blank?
      when "link"
        if raw.key?("url")
          url = text(raw["url"])
          # THE URL IS CAPPED HERE TOO, like every other field with a bound on the row: a draft
          # posted straight at the door has no byte cap of its own (only pasted TEXT does), so
          # without this the one field whose cap lives only in Maker::ProjectBlock would be
          # answered by the model at Save instead of by the entry that named it.
          errors << "Entry #{n}: the url is over #{Maker::ProjectBlock::URL_MAX} characters." if url.length > Maker::ProjectBlock::URL_MAX
          if url.match?(Maker::ProjectBlock::URL_FORMAT)
            e["url"] = url
          else
            errors << "Entry #{n}: url must be an http or https URL."
          end
        end
        set_text(e, raw, "title", Maker::ProjectBlock::HEADING_MAX, n, errors, "the title")
        set_text(e, raw, "line", Maker::ProjectBlock::LINE_MAX, n, errors, "the line")
        # A NEW LINK WITH NO `url:` AT ALL — the branch above answers only a url that was given.
        errors << "Entry #{n}: url must be an http or https URL." if e["url"].blank? && !raw.key?("url")
        errors << "Entry #{n}: a link needs a title." if e["title"].blank?
      when "image"
        if raw.key?("file")
          # A NODE ID FROM THE BROWSER, A PATH FROM THE YAML, and both are one lookup: the draft
          # names what the picker clicked, the text names what a reader can see in the folder.
          given = raw["file"].to_s
          node_id = @images.key?(given) ? given : @paths[given]
          if node_id
            e["file"] = node_id
          elsif new_block
            errors << "Entry #{n}: no image at “#{given}” in the project folder."
          else
            notes << "No image at “#{given}” in the project folder; the block keeps its picture."
          end
        end
        set_text(e, raw, "caption", Maker::ProjectBlock::LINE_MAX, n, errors, "the caption")
        errors << "Entry #{n}: an image block needs a file." if e["file"].blank?
      end
      e
    end

    # A TAB'S ONE ATTRIBUTE. The name is always GIVEN (it is the `tab:` value itself in the YAML and
    # the `name` field in the draft), so there is no absent-keeps arm: blank is an error, never a
    # default (spec decision 6).
    def apply_tab(base, raw, source, n, errors)
      name = text(source == :yaml ? raw["tab"] : raw["name"])
      errors << "Entry #{n}: a tab needs a name." if name.empty?
      errors << "Entry #{n}: the tab name is over #{Maker::ProjectKind::TAB_NAME_MAX} characters." if name.length > Maker::ProjectKind::TAB_NAME_MAX
      { "key" => base["key"], "kind" => "tab", "name" => name.presence }
    end

    def set_text(e, raw, field, max, n, errors, name)
      return unless raw.key?(field)

      value = text(raw[field])
      errors << "Entry #{n}: #{name} is over #{max} characters." if value.length > max
      value.empty? ? e.delete(field) : e[field] = value
    end

    # THE PAGE MERGES LIKE AN ENTRY: what the document gives replaces, what it omits keeps. `raw`
    # nil is a document with no `page` at all — an older browser's draft, or a layout text that
    # says nothing about the intro — and must leave the project's own description alone.
    def merge_page(base_page, raw, notes, errors)
      out = (base_page || @page).dup
      return out if raw.nil?

      raw = raw.to_h { |k, v| [ k.to_s, v ] }
      unknown = raw.keys - PAGE_KEYS
      errors << "Unknown key “#{unknown.first}” under `page`." if unknown.any?
      # STRIPPED, NOT COLLAPSED: the description keeps its line breaks (the page renders it pre-wrap).
      out["description"] = raw["description"].to_s.strip.presence if raw.key?("description")
      if raw.key?("cover")
        given = raw["cover"]
        # AN EXPLICIT NULL CLEARS THE COVER — the Remove button's answer, and the one case where a
        # blank is a value rather than an omission.
        if given.nil? || given.to_s.empty?
          out["cover"] = nil
        else
          node_id = @images.key?(given.to_s) ? given.to_s : @paths[given.to_s]
          if node_id
            out["cover"] = node_id
          else
            notes << "No image at “#{given}” in the project folder; the cover was left as it is."
          end
        end
      end
      out
    end

    def text(value) = value.to_s.gsub(/\s+/, " ").strip

    def label(key)
      # A TAB IS NAMED BY WHAT IT IS, like a block: the duplicate-entry message reads "Entry 4 names
      # the tab a second time", and a tab's own NAME has its own message (two tabs, one name).
      return "the tab" if @layout.tab?(key)
      # A BLOCK HAS NO PANEL LABEL — it is named by what it is, which is all the duplicate-entry
      # message needs ("Entry 4 names the link block a second time").
      return "the #{@layout.block_kind(key) || 'new'} block" if @layout.block?(key)

      @layout.folder?(key) ? @names.fetch(@layout.folder_id(key), key) : Maker::Project::PANEL_LABELS.fetch(key, key)
    end
  end
end
