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

    test "column titles continue past Z the way a spreadsheet does" do
      assert_equal "A",  Maker::Sheet.column_title(0)
      assert_equal "Z",  Maker::Sheet.column_title(25)
      assert_equal "AA", Maker::Sheet.column_title(26)
      assert_equal "AB", Maker::Sheet.column_title(27)
      assert_equal "BA", Maker::Sheet.column_title(52)
    end

    test "blank_data stays rectangular past 26 columns" do
      data = Maker::Sheet.blank_data(rows: 2, columns: 30)
      assert_equal 30, data["columns"].size
      assert_equal 30, data["cells"].first.size
      assert_equal "AD", data["columns"].last["title"]
    end

    test "cells and columns read defensively from a malformed blob" do
      sheet = @project.sheets.create!(user: @user, name: "Odd", data: "not a hash")
      assert_equal [], sheet.cells
      assert_equal [], sheet.columns

      # The OUTER shape: a "cells" key holding a scalar is nothing, not one garbage row.
      sheet.update!(data: { "cells" => "not an array", "columns" => 42 })
      assert_equal [], sheet.cells
      assert_equal [], sheet.columns
    end

    # The ELEMENT shapes, which the outer check above says nothing about. `to_csv` calls
    # `c["title"]` on every column entry, so an Integer or Array entry raised TypeError and a Float
    # or `true` raised NoMethodError — four shapes that survive a real owner PATCH (driven in
    # Web::ProjectSheetsTest; `nil` is the one that does NOT, because deep_munge strips it).
    #
    # BUILT THROUGH create!/reload ON PURPOSE. `permit(data: {})` yields nested
    # `ActionController::Parameters`, and `Parameters.is_a?(Hash)` is FALSE — `grep(Hash)` is only
    # correct because `ActiveRecord::Type::Json#cast` normalises the assignment to a plain Hash.
    # Asserting against an in-memory literal would never exercise that.
    test "cells and columns read defensively from malformed ELEMENTS inside a well-shaped blob" do
      sheet = @project.sheets.create!(user: @user, name: "Ragged", data: {
        "columns" => [ nil, 1, 1.5, true, [ "a" ], { "title" => "Z" } ],
        "cells"   => [ { "a" => 1 }, "nope", 7, [ "x" ] ]
      })
      sheet.reload

      assert_equal [ { "title" => "Z" } ], sheet.columns

      # NORMALISED, NOT DROPPED: projects/_sheets.html.erb renders `cells.size` as "N rows", so a
      # `select` here would silently shrink that count. The size assertion is what pins it — the
      # equality below would still hold for a reader that dropped nothing but reordered nothing.
      assert_equal 4, sheet.cells.size
      assert_equal [ [], [], [], [ "x" ] ], sheet.cells

      assert_equal "Z\n\n\n\nx\n", sheet.to_csv
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

    # `data` is user-controlled JSON written by the browser, permitted whole by the controller, and
    # embedded into the page HTML on EVERY view with no truncation — so the blob size IS the page
    # size. A buggy client or a genuinely huge sheet grew it without bound.
    test "a sheet at the size limit is valid" do
      sheet = @project.sheets.build(user: @user, name: "Big")
      # One long cell sized so the serialised blob lands just under the cap.
      filler = "x" * (Maker::Sheet::MAX_DATA_BYTES - 200)
      sheet.data = { "columns" => [ { "title" => "A", "width" => 120 } ], "cells" => [ [ filler ] ] }
      assert_operator sheet.data.to_json.bytesize, :<=, Maker::Sheet::MAX_DATA_BYTES
      assert sheet.valid?, sheet.errors.full_messages.join(", ")
    end

    test "a sheet over the size limit is rejected" do
      sheet = @project.sheets.build(user: @user, name: "Too big")
      filler = "x" * (Maker::Sheet::MAX_DATA_BYTES + 1000)
      sheet.data = { "columns" => [ { "title" => "A", "width" => 120 } ], "cells" => [ [ filler ] ] }
      assert_not sheet.valid?
      assert_match(/too large/i, sheet.errors.full_messages.join(", "))
    end

    test "a blank sheet is comfortably inside the limit" do
      sheet = @project.sheets.build(user: @user, name: "Blank", data: Maker::Sheet.blank_data)
      assert sheet.valid?
      assert_operator sheet.data.to_json.bytesize, :<, Maker::Sheet::MAX_DATA_BYTES / 100
    end

    # A malformed blob must still reach the DEFENSIVE READERS rather than being rejected here —
    # the readers exist so a half-written blob renders an empty grid instead of 500ing the page,
    # and a size validation that also rejected shape would defeat them.
    test "a malformed blob is not rejected by the size validation" do
      sheet = @project.sheets.build(user: @user, name: "Weird", data: { "cells" => "nonsense" })
      assert sheet.valid?, sheet.errors.full_messages.join(", ")
    end

    # Pins the CONSTANT, not merely the behaviour. Every other test here derives its filler from
    # MAX_DATA_BYTES, so raising the constant rescales them identically and nothing goes red — the
    # coverage catches a limit set too LOW and says nothing about one set too high.
    test "the limit is one mebibyte" do
      assert_equal 1_048_576, Maker::Sheet::MAX_DATA_BYTES
    end
  end
end
