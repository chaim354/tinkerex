module Maker
  # WHAT THE PROJECT'S TYPE HIDES THAT STILL HOLDS ROWS (2026-11-02, the UX audit's C1). A kind's
  # preset hides panels (Maker::ProjectKind::PRESETS: a laser project hides bom, wiring, releases and
  # sheets), and a hidden panel's rows stay in the database. The seeded catan held a three-line BOM,
  # a release and a sheet that its own page gave no way to find: the stats line still counted the
  # sheet, "+ Add panel" offers only EMPTY panels (design-system.md rule 14), and the only door was
  # Edit → Page layout → Show, which nothing pointed at. The hub renders one line from this — "Also
  # in this project: Bill of materials (3 lines) · 1 release · 1 sheet" — each item linking to the
  # panel's own page or to the layout editor's Show control.
  #
  # THE PRESET'S HIDING ONLY, NEVER THE MAKER'S (Maker::ProjectKind.preset_hidden). A panel the maker
  # hid was hidden on purpose, in the layout editor, and its way back is that editor's Show control.
  # The preset's hiding is nobody's choice — the kind is a guess made from the folder's files — and
  # that is the data this finds. It also keeps design-system.md rule 14's S4-7 promise for every
  # panel a maker hides: hiding costs no query (page_query_budget_test.rb compares the two layouts).
  #
  # WHAT THE EDITOR LINK LANDS ON, SAID PLAINLY: ProjectsController#show gates a hidden panel's loads
  # (@connections, @releases, @bom_lines) on `visible?` in edit mode too, so the editor draws a
  # hidden panel GHOSTED and EMPTY — its heading and strip, not its rows. The rows appear once the
  # maker presses Show and saves the layout. The link is a way to the Show control, not a preview of
  # the rows; the BOM page and a lone sheet's page are where rows show without that step.
  #
  # AN EMPTY PANEL IS NOT LISTED: it has nothing to find, and "+ Add panel" speaks for the on-demand
  # ones. CONSTANT IN THE NUMBER OF ROWS: at most one COUNT per preset-hidden panel (two for the
  # BOM: its latest revision, then that revision's lines), and none for Sheets, whose rows the page
  # always loads (pass them as `sheets:`). NOTHING HERE TOUCHES THE PORT.
  class ProjectHiddenRows
    # `count` is the rows the panel holds; `sheet_id` names the one sheet when there is exactly one,
    # whose page is then the panel's own page.
    Entry = Data.define(:key, :count, :sheet_id) do
      def initialize(key:, count:, sheet_id: nil) = super
    end

    # The fixed panels whose rows a maker makes, in the page's default order. Files, Photos, Models
    # and Schematics are not here: the first two cannot be hidden (ProjectKind::ALWAYS), and the
    # last two show what the FOLDER holds, which the Library shows too.
    COUNTED = %w[build_log tasks bom wiring releases sheets calculations].freeze

    def self.for(project:, layout:, sheets: nil)
      hidden = Maker::ProjectKind.preset_hidden(kind: project.kind, overrides: project[:panels])
      COUNTED.select { |key| hidden.include?(key) && layout.hidden?(key) }
             .filter_map { |key| entry_for(project, key, sheets) }
    end

    def self.entry_for(project, key, sheets)
      if key == "sheets"
        ids = sheets ? sheets.map(&:id) : project.sheets.pluck(:id)
        return ids.empty? ? nil : Entry.new(key:, count: ids.size, sheet_id: (ids.first if ids.one?))
      end

      count = case key
      when "build_log"    then project.build_log_entries.count
      when "tasks"        then project.tasks.count
      # The LATEST revision's lines, the one definition the panel and the BOM page both read.
      when "bom"          then project.current_bom&.lines&.count.to_i
      when "wiring"       then project.connections.count
      when "releases"     then project.releases.count
      when "calculations" then project.calculations.count
      end
      count.positive? ? Entry.new(key:, count:) : nil
    end
    private_class_method :entry_for
  end
end
