require "test_helper"

module Maker
  class SheetTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "sheet@example.com")
      @project = @user.maker_projects.create!(name: "Lamp")
    end

    test "valid belonging to a project" do
      sheet = @project.sheets.build(user: @user, name: "Cut list")
      assert sheet.valid?
    end

    test "name is required" do
      sheet = @project.sheets.build(user: @user, name: "")
      assert_not sheet.valid?
    end

    test "a sheet cannot be built on another user's project" do
      other = User.create!(email: "other@example.com")
      theirs = other.maker_projects.create!(name: "Theirs")
      sheet = theirs.sheets.build(user: @user, name: "Sneaky")
      assert_not sheet.valid?
    end

    test "blank_data is a rectangular grid with titled columns" do
      data = Maker::Sheet.blank_data(rows: 3, columns: 2)
      assert_equal 2, data["columns"].size
      assert_equal %w[A B], data["columns"].map { |c| c["title"] }
      assert_equal 3, data["cells"].size
      assert_equal [ "", "" ], data["cells"].first
    end

    test "cells and columns read defensively from a malformed blob" do
      sheet = @project.sheets.create!(user: @user, name: "Odd", data: "not a hash")
      assert_equal [], sheet.cells
      assert_equal [], sheet.columns
    end

    test "to_csv writes the column titles then the cells" do
      sheet = @project.sheets.create!(user: @user, name: "Costs", data: {
        "columns" => [ { "title" => "Part" }, { "title" => "Qty" } ],
        "cells"   => [ [ "M3 bolt", "12" ], [ "Insert", "8" ] ]
      })
      assert_equal "Part,Qty\nM3 bolt,12\nInsert,8\n", sheet.to_csv
    end

    test "to_csv quotes a cell containing a comma" do
      sheet = @project.sheets.create!(user: @user, name: "Costs", data: {
        "columns" => [ { "title" => "Part" } ],
        "cells"   => [ [ "bolt, hex" ] ]
      })
      assert_equal "Part\n\"bolt, hex\"\n", sheet.to_csv
    end

    test "destroying the project destroys its sheets" do
      @project.sheets.create!(user: @user, name: "Cut list")
      assert_difference -> { Maker::Sheet.count }, -1 do
        @project.destroy!
      end
    end
  end
end
