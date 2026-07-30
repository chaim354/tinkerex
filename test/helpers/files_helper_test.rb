require "test_helper"

class FilesHelperTest < ActiveSupport::TestCase
  # The existing tests here only read constants; `recipe_num` is an instance method, so mix the
  # module in rather than moving the whole file to ActionView::TestCase for one helper.
  include FilesHelper

  # THE TEST THAT MAKES "ONE VOCABULARY" A PROPERTY RATHER THAN A COINCIDENCE. Before this, the
  # chips and the project panel headings were two hand-written lists that named overlapping files
  # differently (.svg was "2D / laser" on one page and "Vector" on the other) and left the five
  # cad_source extensions with no chip at all. A hand-written family re-added later fails here.
  test "every chip extension comes from the role vocabulary" do
    assert_equal Maker::FileAttachment::ROLE_BY_EXT.keys.sort,
                 FilesHelper::EXT_FAMILIES.values.flatten.sort
  end

  test "every chip family is a role label" do
    assert_empty FilesHelper::EXT_FAMILIES.keys - Maker::FileAttachment::ROLE_LABELS.values
  end

  # `other` is a FALLBACK for unrecognised extensions, not an extension set — it has nothing to
  # render chips from, and a family with no extensions would render an empty labelled row.
  test "the other role contributes no family" do
    assert_not_includes FilesHelper::EXT_FAMILIES.keys, "Other"
    assert FilesHelper::EXT_FAMILIES.values.none?(&:empty?)
  end

  test "the families follow ROLE_LABELS order" do
    expected = Maker::FileAttachment::ROLE_LABELS.values & FilesHelper::EXT_FAMILIES.keys
    assert_equal expected, FilesHelper::EXT_FAMILIES.keys
  end

  # The complaint this item started from.
  test "cad_source extensions now have a chip" do
    assert_includes FilesHelper::EXT_FAMILIES["CAD source"], "scad"
    assert_includes FilesHelper::EXT_FAMILIES["CAD source"], "sldprt"
  end

  # Every chip extension must be one FilesController will actually accept, or the chip is a control
  # that renders, links and silently does nothing. `markdown` is exactly 8 characters — the bound.
  test "every chip extension satisfies the controller's EXT_RE" do
    FilesHelper::EXT_FAMILIES.values.flatten.each do |ext|
      assert_match FilesController::EXT_RE, ext, "#{ext} would be dropped by the controller"
    end
  end

  # RECIPE NUMBERS. The laser/CNC panels used `.to_i`, which TRUNCATES: a layer cut at 6.67 mm/s
  # rendered "6 mm/s" — a 10 % error on the number the machine actually runs, shown as though it
  # were the setting. Every checked-in .lbrn2 fixture uses whole speeds and powers, so no test
  # could see it; the value that exposed it came off a real file.
  #
  # The other half is that the raw float is not printable either — a metadata Hash holds 50.0 and
  # 13.0, and "50.0 mm/s" is noise. So: round (never truncate), then drop a trailing zero that
  # carries no information.
  test "recipe_num keeps the decimals a value actually has" do
    assert_equal "6.67",  recipe_num(6.67)
    assert_equal "3.175", recipe_num(3.175)
    assert_equal "14.8",  recipe_num(14.8)
    assert_equal "0.5",   recipe_num(0.5)
  end

  test "recipe_num drops a meaningless trailing zero" do
    assert_equal "50",    recipe_num(50.0)
    assert_equal "13",    recipe_num(13.0)
    assert_equal "20000", recipe_num(20000.0)
    assert_equal "0",     recipe_num(0.0)
  end

  # MillMage stores 1/8" as 3.1749999523162842 and a feed rate as 14.800000190734863. Three
  # decimals is what MageMetadata already rounds tool values to, so the panel agrees with the
  # stored Hash instead of printing sixteen digits of binary noise.
  test "recipe_num rounds float noise to three decimals rather than showing it" do
    assert_equal "3.175", recipe_num(3.1749999523162842)
    assert_equal "14.8",  recipe_num(14.800000190734863)
  end

  # The metadata Hash comes out of a JSON column and is best-effort by design (LbrnMetadata omits
  # what it cannot read), so the panel has to survive a missing or junk value without rendering
  # the word "nil" next to a unit.
  test "recipe_num answers nil for anything that is not a number" do
    assert_nil recipe_num(nil)
    assert_nil recipe_num("")
    assert_nil recipe_num("fast")
  end

  test "recipe_num accepts a numeric string, since JSON round-trips are not guaranteed" do
    assert_equal "6.67", recipe_num("6.67")
    assert_equal "15",   recipe_num("15")
  end
end
