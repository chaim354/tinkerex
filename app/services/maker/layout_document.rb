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
  # PURE: takes a Layout and a { node_id => name } map, touches no row and no port, so every rule
  # runs identically on the three backend legs. Psych's `safe_load` with no permitted classes and
  # a 16 KB cap is the whole of the parsing surface.
  class LayoutDocument
    VERSION = 1
    MAX_BYTES = 16 * 1024
    ATTRIBUTES = %w[title intro width view hidden].freeze

    Result = Data.define(:draft, :notes, :errors) do
      def ok? = errors.empty?
    end

    def initialize(layout, folder_names)
      @layout = layout
      @names = folder_names.to_h { |id, name| [ id.to_s, name.to_s ] }
    end

    # --- the draft ---------------------------------------------------------------------------

    def draft
      { "layout" => VERSION, "panels" => @layout.order.map { |key| entry(key) } }
    end

    # --- export ------------------------------------------------------------------------------

    def to_yaml(draft = self.draft, project_name:)
      panels = draft["panels"].filter_map do |e|
        out = {}
        if @layout.folder?(e["key"])
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
        out["title"] = e["title"] if e["title"]
        out["intro"] = e["intro"] if e["intro"]
        out["width"] = e["width"]
        out["view"] = e["view"] if e["view"]
        out["hidden"] = true if e["hidden"]
        out
      end
      body = Psych.dump({ "layout" => VERSION, "panels" => panels }, line_width: -1).delete_prefix("---\n")
      "# #{project_name.to_s.gsub(/\s+/, ' ').strip}, page layout. Paste into another project's editor to reuse it.\n#{body}"
    end

    # --- parse: YAML text in ---------------------------------------------------------------------

    def parse(text)
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

      unknown = data.keys.map(&:to_s) - %w[layout panels]
      return failure("Unknown key “#{unknown.first}” at the top level.") if unknown.any?
      return failure("`panels` must be a list.") unless data["panels"].is_a?(Array)

      merge(data["panels"], :yaml)
    end

    # --- from_draft: the browser's JSON in ----------------------------------------------------------

    def from_draft(hash)
      return failure("Not a layout draft.") unless hash.is_a?(Hash) && hash["panels"].is_a?(Array)

      merge(hash["panels"], :draft)
    end

    # --- the column -------------------------------------------------------------------------------

    def column(draft)
      panels = draft["panels"]
      { "order" => panels.map { |e| e["key"] },
        "hidden" => panels.select { |e| e["hidden"] }.map { |e| e["key"] },
        "views" => panels.filter_map { |e| [ e["key"], e["view"] ] if e["view"] }.to_h,
        # WIDTHS ARE WRITTEN FOR EVERY PANEL, DEFAULTS INCLUDED, BY DESIGN: a Save records the
        # arrangement the maker saw and approved, and the width is a control they operated. A folder
        # added later still falls through to default_width (Layout#width_for is `||`), so this is
        # additive, not the freezing bug the retired chooser's move branch had. Titles stay sparse
        # for the opposite reason: a maker never chose a default label, so a PANEL_LABELS change
        # must still reach a saved project. Do not "tidy" this into a filter on non-defaults.
        "widths" => panels.to_h { |e| [ e["key"], e["width"] ] },
        "titles" => panels.filter_map { |e| [ e["key"], e["title"] ] if e["title"] }.to_h,
        "intros" => panels.filter_map { |e| [ e["key"], e["intro"] ] if e["intro"] }.to_h }
    end

    private

    def entry(key)
      e = { "key" => key, "hidden" => @layout.hidden?(key), "width" => @layout.width_for(key) }
      e["view"] = @layout.view_for(key) if Maker::ProjectKind.offered_views(key).any?
      e["title"] = @layout.titles[key] if @layout.titles[key]
      e["intro"] = @layout.intros[key] if @layout.intros[key]
      e
    end

    def failure(message) = Result.new(draft: draft, notes: [], errors: [ message ])

    # The merge, shared by both doors. `source` says how an entry names its panel: `:yaml` by
    # `panel:`/`folder:` (names), `:draft` by `key`. Everything after the key is one code path.
    def merge(raw_entries, source)
      notes, errors = [], []
      current = draft["panels"].to_h { |e| [ e["key"], e ] }
      listed = []

      raw_entries.each_with_index do |raw, i|
        n = i + 1
        unless raw.is_a?(Hash)
          errors << "Entry #{n} is not a mapping."
          next
        end
        raw = raw.to_h { |k, v| [ k.to_s, v ] }
        key = source == :yaml ? key_from_yaml(raw, n, notes, errors) : key_from_draft(raw, n, notes, errors)
        next unless key

        unknown = raw.keys - (source == :yaml ? %w[panel folder] : %w[key]) - ATTRIBUTES
        errors << "Entry #{n}: unknown attribute “#{unknown.first}”." if unknown.any?
        if listed.any? { |k, _| k == key }
          errors << "Entry #{n} names #{label(key)} a second time."
          next
        end
        listed << [ key, apply(current.fetch(key), raw, key, n, notes, errors) ]
      end
      return Result.new(draft: draft, notes: notes, errors: errors) if errors.any?

      ordered = listed.map(&:last) + (current.keys - listed.map(&:first)).map { |k| current[k] }
      if listed.any? { |k, _| k == "publish" } && ordered.last["key"] != "publish"
        publish = ordered.find { |e| e["key"] == "publish" }
        ordered = (ordered - [ publish ]) + [ publish ]
        notes << "Publish is always last; it was moved to the end."
      end
      Result.new(draft: { "layout" => VERSION, "panels" => ordered }, notes: notes, errors: errors)
    end

    def key_from_yaml(raw, n, notes, errors)
      if raw.key?("panel") && raw.key?("folder")
        errors << "Entry #{n} names both `panel` and `folder`; use one."
        return nil
      end
      if raw.key?("panel")
        key = raw["panel"].to_s
        return key if Maker::Project::PANELS.include?(key)

        errors << "Entry #{n}: unknown panel “#{key}”."
        return nil
      end
      if raw.key?("folder")
        name = raw["folder"].to_s
        id = @names.key(name)
        return Maker::ProjectKind.folder_key(id) if id && @layout.order.include?(Maker::ProjectKind.folder_key(id))

        notes << "This project has no folder named “#{name}”; that entry was skipped."
        return nil
      end
      errors << "Entry #{n} names neither `panel` nor `folder`."
      nil
    end

    def key_from_draft(raw, n, notes, errors)
      key = raw["key"].to_s
      return key if @layout.order.include?(key)

      if @layout.folder?(key)
        # A FOLDER RENAMED ON DISK MID-EDIT (share/s3 mint a new dir id on rename — the layout's
        # own header): the key left the vocabulary between the page render and this Save.
        notes << "A folder changed on disk while you were editing; its panel keeps its defaults."
      else
        errors << "Entry #{n}: unknown panel “#{key}”."
      end
      nil
    end

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

    def text(value) = value.to_s.gsub(/\s+/, " ").strip

    def label(key)
      @layout.folder?(key) ? @names.fetch(@layout.folder_id(key), key) : Maker::Project::PANEL_LABELS.fetch(key, key)
    end
  end
end
