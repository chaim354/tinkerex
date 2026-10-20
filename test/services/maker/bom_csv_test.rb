require "test_helper"
require "support/public_fixture"

module Maker
  # STAGE 3, S3-6: the public BOM as CSV.
  #
  # THE SUBJECT IS THE PART RULE, and it is a privacy rule dressed as a formatting one: a design-file
  # line may point at ANY node in the owner's library, and the public partial refuses to name one
  # the project does not permit because the file route would 404 it — a CSV that named it would
  # publish a private filename in a document people mail around. Every case below is one target
  # kind or one refusal.
  #
  # THE SHARE PIN IS test/support/public_fixture.rb's; `Maker::PublicProject` walks the owner's
  # library, and a fixture whose nodes have bytes on one backend only is what that header records.
  class BomCsvTest < ActiveSupport::TestCase
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user)
      @project = @f[:project]
      @bom = @f[:bom]
    end

    teardown { FileLayer.reset! }

    def rows(lines = nil)
      pub = Maker::PublicProject.new(@project.reload)
      CSV.parse(Maker::BomCsv.render(lines || pub.bom_lines, pub))
    end

    def row_for(reference) = rows.find { |r| r.first == reference }

    test "the header is the five columns and nothing else" do
      assert_equal %w[reference part quantity unit file], rows.first
    end

    test "an inventory-item line names the item" do
      assert_equal [ "B1", "M3 bolt", "2.0", "each", nil ], row_for("B1")
    end

    # THE PUBLIC TABLE'S UNIT RULE, IN THE SECOND MEDIUM (audit F-S16-2): a stock line's unit is its
    # item's, read from the item. The fixture saved the line in "each", so after this edit a CSV that
    # writes the line's own column still says "each" while the page says "pack".
    test "an inventory-item line's unit is its item's current unit" do
      @f[:item].update!(unit: "pack")

      assert_equal [ "B1", "M3 bolt", "2.0", "pack", nil ], row_for("B1")
    end

    test "a design-file line the project permits names the file and its path in the bundle" do
      assert_equal [ "F1", "base.stl", "1.0", "each", "models/base.stl" ], row_for("F1")
    end

    test "a free-text line names its own text" do
      assert_equal [ "T1", "22 AWG wire", "3.0", "m", nil ], row_for("T1")
    end

    # THE REFUSAL, TWICE OVER: the part column falls back to the line's free text (blank here, since
    # a line carrying both a node and a part_name is not a valid line), and the file column is empty
    # rather than naming a file this project cannot deliver.
    test "a design-file line pointing outside the project names neither the file nor its path" do
      @bom.lines.create!(user: @user, node_id: @f[:outsider].node_id, quantity: 1, unit: "each",
                         reference: "X1")

      assert_equal [ "X1", nil, "1.0", "each", nil ], row_for("X1")
      refute_includes Maker::BomCsv.render(Maker::PublicProject.new(@project.reload).bom_lines,
                                           Maker::PublicProject.new(@project.reload)),
                      "elsewhere.stl"
    end

    test "a design-file line whose node was tombstoned names nothing either" do
      @f[:base].update!(deleted: true)

      assert_equal [ "F1", nil, "1.0", "each", nil ], row_for("F1")
    end

    # CSV, NOT STRING JOINING — a part name with a comma in it is the case a `map(&:to_s).join(",")`
    # implementation passes every other test with and silently splits a column on.
    test "a comma in a part name is quoted, not a new column" do
      @bom.lines.create!(user: @user, part_name: "wire, 22 AWG", quantity: 1, unit: "m",
                         reference: "C1")

      assert_equal [ "C1", "wire, 22 AWG", "1.0", "m", nil ], row_for("C1")
      assert_includes Maker::BomCsv.render(Maker::PublicProject.new(@project.reload).bom_lines,
                                           Maker::PublicProject.new(@project.reload)),
                      %("wire, 22 AWG")
    end

    # A STRANGER OPENS THIS FILE IN A SPREADSHEET: a cell beginning `=`, `+`, `-`, `@`, a tab or a
    # carriage return is a formula to Excel and Sheets, so a published part name of
    # `=HYPERLINK(...)` would run in the visitor's sheet. Defused with a leading apostrophe, in every
    # text column, and only in THIS export -- Maker::Sheet#to_csv keeps formulas on purpose, because
    # that is the owner downloading their own sheet (S3-6's review).
    test "a cell that would be a spreadsheet formula is defused with a leading apostrophe" do
      @bom.lines.create!(user: @user, part_name: %(=HYPERLINK("https://evil.example","click")),
                         quantity: 1, unit: "each", reference: "-R1")
      @bom.lines.create!(user: @user, part_name: "@mention", quantity: 2, unit: "each", reference: "+R2")

      assert_equal [ "'-R1", %('=HYPERLINK("https://evil.example","click")), "1.0", "each", nil ], row_for("'-R1")
      assert_equal [ "'+R2", "'@mention", "2.0", "each", nil ], row_for("'+R2")
      assert_equal [ "B1", "M3 bolt", "2.0", "each", nil ], row_for("B1"), "an ordinary cell is untouched"
    end

    test "no lines is a header-only document" do
      assert_equal [ %w[reference part quantity unit file] ], rows([])
    end

    # THE OMISSIONS, ASSERTED AS OMISSIONS. The fixture's item carries 7 on hand and a supplier, and
    # both are one `line.supplier&.name` away from being in this file forever.
    test "stock and supplier never appear" do
      csv = Maker::BomCsv.render(Maker::PublicProject.new(@project).bom_lines,
                                 Maker::PublicProject.new(@project))

      refute_includes csv, "Acme Supply"
      refute_includes csv.downcase, "supplier"
      refute_includes csv.downcase, "stock"
    end
  end
end
