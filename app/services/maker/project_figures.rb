module Maker
  # THE PROJECT PAGE'S FIGURES, IN THE ORDER THE PAGE DRAWS THEM (the Shop manual spec §9: "number
  # files by panel order, then file order"). ProjectsController#show builds one per render from what
  # it has already loaded, so the walk costs no query; Maker::FigureNumbers turns it into numbers.
  #
  # THE WALK IS THE PAGE'S OWN ORDER, AND EACH STEP NAMES THE PARTIAL IT MIRRORS:
  #   1. the cover (projects/_hero), when the head draws one: Fig. 1, as the screens number it, and
  #      the same file keeps 1 wherever a panel draws it again;
  #   2. every visible panel in the layout's order, the top group's and then each tab's
  #      (projects/_panel_groups), each drawing its files in its own order:
  #        * Files (projects/_attachments): Loose, as figures (a stack is one), then Generated,
  #          Backups and Linked from elsewhere;
  #        * a folder panel (projects/_folder_panel): its own files as figures, then each nested
  #          section depth first (projects/_file_tree_section). A panel in the BROWSER draws no
  #          figure, and nor does a repository nested inside a panel: both are navigated, not drawn;
  #        * Photos (projects/_photos), Schematics' list (projects/_schematics) and an image block's
  #          picture (projects/_block_panel), one figure per file;
  #        * nothing else draws a figure. A README, a BOM line or a build-log photo CITES one.
  # The Files panel's "Recently changed" row is a second look at files filed below it, so it numbers
  # nothing: its tiles carry the numbers their files have where they are filed, and a recent file no
  # panel draws carries none. A figure the page draws inside a closed <details> (Backups) is still a
  # figure.
  #
  # NUMBERS ARE TAKEN WHERE THE WALK SAYS AND CHECKED WHERE THE PAGE DRAWS: figure_numbers_test.rb
  # reads every callout off the rendered page and holds that, in document order, each number first
  # appears in turn, 1, 2, 3, with no gap, so a partial that changes its order without this walk
  # changing with it goes red.
  #
  # `stack_figures` IS THE ONE DEFINITION OF WHAT A GROUP OF ROWS DRAWS when its panel stacks — the
  # walk calls it here and every partial through ProjectsHelper#stack_figures — so the figures the
  # page draws and the figures this numbers are one list by construction.
  class ProjectFigures
    # ONE VERSION STACK AMONG A PANEL'S FIGURES (spec §9): the stack and its members' rows, latest
    # first, so a tile or a list row can draw the latest and open onto the rest.
    StackFigure = Data.define(:stack, :rows) do
      def latest = rows.first
      def node_ids = rows.map(&:node_id)
    end

    # WHAT A GROUP OF ROWS DRAWS, IN ORDER: each Row that stands alone, and a StackFigure where a
    # stack's first member stood (Maker::VersionStacks::Result#collapse over the page's `stacks`).
    # `folder_id` names the folder these rows sit in, so the backups that stack with them
    # (`stacked_backups`, keyed by folder) join them here rather than in the Files panel's Backups
    # group. A panel whose switch is off has no stacks in `stacks`, so its rows come back as they went
    # in. A stack missing a member's row (it cannot: the rows are what was grouped) is drawn as the
    # rows it has.
    def self.stack_figures(rows, stacks:, stacked_backups:, folder_id: nil)
      all = rows + Array(stacked_backups&.fetch(folder_id, nil))
      return all if stacks.nil? || stacks.stacks.empty?

      by_id = all.index_by(&:node_id)
      stacks.collapse(all.map(&:node_id)).flat_map do |figure|
        next [ by_id[figure] ] unless figure.is_a?(Maker::VersionStacks::Stack)

        members = figure.node_ids.filter_map { |id| by_id[id] }
        members.size == figure.size ? [ StackFigure.new(stack: figure, rows: members) ] : members
      end
    end

    # The node ids one drawn figure stands for.
    def self.ids_of(figure) = figure.is_a?(StackFigure) ? figure.node_ids : [ figure.node_id ]

    # Inputs are ProjectsController#show's own: the layout, the listing, the cover's id (nil when the
    # head draws none), Generated (node_id => state, in the order the group draws), the README panel's
    # row id, the stacks and the backups they hold, the Linked rows, the Photos rows, the blocks by
    # layout key and the page's live-node index (an image block draws only a live picture).
    def initialize(layout:, listing:, cover_id:, generated:, readme_row_id:, stacks:, stacked_backups:,
                   linked_rows:, photo_rows:, blocks_by_key:, page_nodes:)
      @layout = layout
      @listing = listing
      @cover_id = cover_id
      @generated = generated
      @generated_ids = generated.keys.to_set
      @readme_row_id = readme_row_id
      @stacks = stacks
      @stacked_backups = stacked_backups
      @linked_rows = linked_rows
      @photo_rows = photo_rows
      @blocks_by_key = blocks_by_key
      @page_nodes = page_nodes
    end

    def numbers
      @numbers ||= FigureNumbers.build do |numbers|
        numbers.figure(@cover_id, place: "hero") if @cover_id
        page_keys.each do |key|
          each_figure(key) { |ids| numbers.figure(ids, place: key) }
        end
      end
    end

    private

    # THE PAGE'S PANEL ORDER: the top group, then each tab's panels (projects/_panel_groups draws the
    # top grid above the tab bar). Hidden panels are not on the page; the on-demand panels the page
    # leaves out while empty draw no figure, so the walk need not know which they are.
    def page_keys
      groups = @layout.groups(@layout.visible)
      groups.top + groups.tabs.flat_map(&:keys)
    end

    def each_figure(key, &)
      if @layout.block?(key)
        block = @blocks_by_key[key]
        yield [ block.node_id ] if block&.kind == "image" && @page_nodes.key?(block.node_id)
      elsif @layout.folder?(key)
        folder_figures(key, &)
      else
        case key
        when "attachments" then files_figures(&)
        when "photos" then @photo_rows.each { |row| yield [ row.node_id ] }
        when "schematics" then schematic_rows.each { |row| yield [ row.node_id ] }
        end
      end
    end

    # projects/_attachments: Loose (stacked), Generated, Backups, Linked.
    def files_figures(&)
      loose = @listing.loose.reject { |r| @generated_ids.include?(r.node_id) || r.node_id == @readme_row_id }
      figures_of(loose, @listing.folder_id, &) if loose.any?
      @generated.each_key { |id| yield [ id ] if @listing.row_for(id) }
      @listing.backups.each do |row|
        yield [ row.node_id ] unless @generated_ids.include?(row.node_id) || @stacks&.stacked?(row.node_id)
      end
      @linked_rows.each { |row| yield [ row.node_id ] }
    end

    # projects/_folder_panel: nothing in the browser, else its files, then its nested sections.
    def folder_figures(key, &)
      return if @layout.view_for(key) == "browser"

      dir = @listing.tree.find { |d| d.node_id == @layout.folder_id(key) }
      dir_figures(dir, &) if dir
    end

    # projects/_file_tree_section, recursively; a nested repository is a closed browser.
    def dir_figures(dir, &)
      figures_of(dir.files.reject { |row| @generated_ids.include?(row.node_id) }, dir.node_id, &)
      dir.children.each { |child| dir_figures(child, &) unless child.repo? }
    end

    def figures_of(rows, folder_id)
      self.class.stack_figures(rows, stacks: @stacks, stacked_backups: @stacked_backups, folder_id:)
          .each { |figure| yield self.class.ids_of(figure) }
    end

    # projects/_schematics: every KiCad file in the folder, by name.
    def schematic_rows
      @listing.all_rows.select { |row| FilePreview::KICANVAS_EXTS.include?(File.extname(row.node.name).downcase.delete(".")) }
              .sort_by { |row| row.node.name }
    end
  end
end
