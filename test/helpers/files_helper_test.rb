require "test_helper"

class FilesHelperTest < ActiveSupport::TestCase
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
end
