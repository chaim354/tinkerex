module Maker
  # THE TOOLS PINNED TO THE SIDEBAR (2026-10-22): the built-in calculator and any addon, in the order
  # the maker pinned them. A right click on a tool's card in the gallery, or on its pinned link in
  # the rail, pins or unpins it (toolmenu_controller.js, Tools::PinsController).
  #
  # HELD IN `users.pinned_tools`, A JSON LIST, AND AN ADDON'S TITLE IS COPIED IN AT PIN TIME. The
  # rail renders on every page and THE LAYOUT NEVER READS THE ADDON REGISTRY (docs/invariants/addons.md;
  # new_menu_test.rb counts it) — a manifest fetch over HTTP behind a five-minute cache, whose outage
  # must cost a page nothing. So the rail draws from what the user row already holds, and a renamed
  # addon shows its old title until it is pinned again. A pinned addon the source no longer serves
  # stays in the rail, its link a 404, until the maker unpins it there; unpinning reads only this
  # list, never the registry, so it always can.
  #
  # The column is client-shaped data only in the sense that this class wrote it; it is still read
  # defensively, so a hand-edited or junk entry is skipped rather than raised on in the layout.
  class ToolPins
    include Enumerable

    CALCULATOR = "calculator".freeze

    Pin = Data.define(:key, :title) do
      def calculator? = key == CALCULATOR

      # What the rail and the menus call it. The calculator is built in, so its name lives here and
      # not in the row; an addon falls back to its key only if its copied title was lost.
      def label = calculator? ? "Calculator" : title.presence || key
    end

    def initialize(user)
      @user = user
    end

    def each(&) = pins.each(&)

    def pinned?(key) = pins.any? { |pin| pin.key == key.to_s }

    def find(key) = pins.find { |pin| pin.key == key.to_s }

    # Appends, so the rail keeps the order things were pinned in. Pinning what is already pinned
    # changes nothing (a double click, or two tabs).
    def pin!(key, title: nil)
      return if pinned?(key)

      write(pins.map { |pin| entry(pin) } + [ entry(Pin.new(key: key.to_s, title:)) ])
    end

    def unpin!(key) = write(pins.reject { |pin| pin.key == key.to_s }.map { |pin| entry(pin) })

    private

    def pins
      @pins ||= Array(@user.pinned_tools).filter_map do |raw|
        next unless raw.is_a?(Hash) && raw["key"].is_a?(String) && raw["key"].present?

        Pin.new(key: raw["key"], title: raw["title"].is_a?(String) ? raw["title"] : nil)
      end.uniq(&:key)
    end

    def entry(pin) = { "key" => pin.key, "title" => pin.title }.compact

    # `update_column`, NOT `update!`, as the calculator's flag was written: a display preference must
    # not be refused by validations that have nothing to do with it. A legacy row whose handle a later
    # RESERVED_HANDLES entry now excludes (`calculations` joined that list with the calculator) would
    # otherwise fail every pin with a 500 about a field the maker never touched.
    def write(entries)
      @user.update_column(:pinned_tools, entries)
      @pins = nil
    end
  end
end
