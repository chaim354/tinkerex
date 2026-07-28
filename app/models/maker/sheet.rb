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

    validates :name, presence: true
    validate  :project_belongs_to_user

    # A blank workbook, spreadsheet-conventional A/B/C column titles.
    def self.blank_data(rows: DEFAULT_ROWS, columns: DEFAULT_COLUMNS)
      titles = ("A".."Z").first(columns)
      {
        "columns" => titles.map { |t| { "title" => t, "width" => 120 } },
        "cells"   => Array.new(rows) { Array.new(columns, "") }
      }
    end

    # Defensive readers: `data` is written by the browser, so a malformed or half-written blob must
    # render an empty grid rather than 500 the page.
    def cells   = data.is_a?(Hash) ? Array(data["cells"]) : []
    def columns = data.is_a?(Hash) ? Array(data["columns"]) : []

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
  end
end
