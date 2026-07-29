require "csv"

module Maker
  # A free-form spreadsheet on a project — cut lists, cost math, measurements. The whole workbook
  # lives in one JSON blob rather than a normalized cells table: a sheet is read and written whole
  # by the grid, nothing queries across cells, and the single-user scale this targets never makes
  # the blob the bottleneck. If it ever does, a cells table slots in behind the same controller.
  class Sheet < ApplicationRecord
    self.table_name = "maker_sheets"

    belongs_to :user
    belongs_to :project, class_name: "Maker::Project"

    DEFAULT_ROWS    = 20
    DEFAULT_COLUMNS = 6

    # The blob is embedded into the page HTML on EVERY view with no truncation (see
    # projects/sheets/show.html.erb), so this bounds the PAGE, not just the row.
    #
    # The arithmetic, so the number is not mistaken for a guess: `blank_data` (20x6) is ~600 bytes;
    # a large but genuinely plausible sheet — 1000 rows x 20 columns, cells averaging 8 characters —
    # is ~220 KB. 1 MB is ~4.5x that.
    #
    # BYTESIZE, NOT ROW/COLUMN CAPS: one number, and it is the quantity that actually hurts. Row and
    # column caps reject legitimately-shaped sheets while still permitting an enormous one.
    MAX_DATA_BYTES = 1_048_576

    validates :name, presence: true
    validate  :project_belongs_to_user
    validate  :data_within_size_limit

    # A…Z, then AA, AB, … — spreadsheet convention. NOT `("A".."Z").first(columns)`: Range#first
    # silently returns fewer than asked past Z, which produced 26 headers over 30-wide rows.
    def self.column_title(index)
      title = +""
      n = index
      loop do
        title.prepend((("A".ord + (n % 26))).chr)
        n = n / 26 - 1
        break if n.negative?
      end
      title
    end

    # A blank workbook, spreadsheet-conventional A/B/C column titles.
    def self.blank_data(rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS)
      {
        "columns" => Array.new(columns) { |i| { "title" => column_title(i), "width" => 120 } },
        "cells"   => Array.new(rows) { Array.new(columns, "") }
      }
    end

    # Defensive readers: `data` is written by the browser, so a malformed or half-written blob must
    # render an empty grid rather than 500 the page. The INNER shape is checked too — Array("x")
    # wraps a bare String into a one-element array, so a "cells" key holding a scalar would
    # otherwise become one garbage row rather than nothing.
    def cells   = data.is_a?(Hash) && data["cells"].is_a?(Array) ? data["cells"] : []
    def columns = data.is_a?(Hash) && data["columns"].is_a?(Array) ? data["columns"] : []

    # Exports what is STORED, which means a formula exports as `=A1*B1`, not as its result. That is
    # the intent: the export is the sheet, not a snapshot of its output.
    def to_csv
      CSV.generate do |csv|
        csv << columns.map { |c| c["title"].to_s }
        cells.each { |row| csv << Array(row).map(&:to_s) }
      end
    end

    private

    def project_belongs_to_user
      unless Maker::Project.exists?(id: project_id, user_id: user_id)
        errors.add(:project_id, "must reference your own project")
      end
    end

    # Deliberately says NOTHING about shape. `data` is permitted whole by the controller and
    # defended at render time by the `cells`/`columns` readers; a validation that also rejected a
    # malformed blob would turn a recoverable empty grid into a save the user cannot complete.
    #
    # RAW DELIMITED BYTES, NOT number_to_human_size: the sheet grows by debounced autosave one
    # keystroke at a time, so a user's first rejection is always just a few bytes over the cap —
    # and number_to_human_size rounds both sides identically for roughly the first 5,242 bytes of
    # overage, producing "is too large (1 MB; limit 1 MB)" for exactly the case that hits first.
    # `precision:` does not fix this; it is the same rounding at a different threshold.
    def data_within_size_limit
      return if data.nil?
      size = data.to_json.bytesize
      return if size <= MAX_DATA_BYTES
      errors.add(:data, "is too large (#{ActiveSupport::NumberHelper.number_to_delimited(size)} bytes; " \
                        "limit #{ActiveSupport::NumberHelper.number_to_delimited(MAX_DATA_BYTES)} bytes)")
    end
  end
end
