module Maker
  # FIGURE NUMBERS (the Shop manual spec §9 and §11.3): the red numbered callout on each figure of a
  # project page, the number a citation and the index of files quote, and what the find box jumps to.
  #
  # POSITIONAL, NEVER STORED. A number is where a figure first appears in the page's own order, so it
  # shifts when a file is added, a panel moves or a stack switch flips; it is for finding a file on
  # the page, never for citing it anywhere else (§11.3). Nothing here reads or writes the database.
  #
  # THE CORE IS THIS CLASS, AND IT KNOWS NOTHING ABOUT PANELS: a caller walks its page in drawing
  # order and hands each FIGURE over as the node ids it stands for, one for a file, every member for a
  # version stack. The first drawing of a figure takes the next number, and every member takes it;
  # a later drawing of the same file (the cover again in its panel, an image again in Photos) is the
  # same figure and keeps the number it has. A figure one of whose members is already numbered takes
  # that member's number, so a file never carries two. Maker::ProjectFigures is the project page's
  # walk and Maker::PublicProject#figure_numbers the visitor's.
  #
  # `place` is the panel key a drawing is in ("hero" for the cover): a figure records the first, and
  # `drawn_places` every one, which is what the page reads to know which panels a switch that moves
  # the numbers must redraw (ProjectsController#switched_panel_streams).
  class FigureNumbers
    Figure = Data.define(:number, :node_ids, :place)

    # A walk that numbers nothing: the editor's, and any page that draws no figure.
    def self.build
      numbers = new
      yield numbers if block_given?
      numbers
    end

    def initialize
      @by_id = {}
      @figures = []
      @drawn = []
    end

    # ONE DRAWING OF A FIGURE, in page order. Returns its number, or nil for a figure with no ids.
    def figure(node_ids, place: nil)
      ids = Array(node_ids).compact.uniq
      return if ids.empty?

      @drawn << place unless place.nil? || @drawn.include?(place)

      number = ids.filter_map { |id| @by_id[id] }.first
      unless number
        number = @figures.size + 1
        @figures << Figure.new(number:, node_ids: ids, place:)
      end
      ids.each { |id| @by_id[id] ||= number }
      number
    end

    # The number a file carries on this page, or nil when the page draws it as no figure.
    def number(node_id) = @by_id[node_id]

    def figures = @figures
    def size = @figures.size
    def any? = @figures.any?
    def empty? = @figures.empty?

    # The panel keys whose drawing of a figure was its first, in page order.
    def places = @figures.map(&:place).uniq

    # Every panel key that draws a figure, its first drawing or a later one, in page order: what a
    # renumbering redraws (ProjectsController#switched_panel_streams).
    def drawn_places = @drawn
  end
end
