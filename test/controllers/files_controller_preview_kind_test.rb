require "test_helper"

# FilesController#preview_kind — which preview a filename gets, and above all that its `:text` set
# is DERIVED from Maker::FileAttachment's one vocabulary rather than being a second extension list
# beside it (§14d). Until 2026-08-25 it carried its own inline list of 26 extensions; the frozen
# literal below is what keeps that list from coming back.
#
# UNIT-LEVEL ON PURPOSE. `preview_kind` is pure — a filename in, a symbol out — so driving three
# dozen real uploads to ask a question about a lookup would be slower and no more true. The one
# thing a direct call cannot show, that the detail PAGE renders the text container for a source
# file, is driven as a real request in test/integration/web/files_flow_test.rb.
class FilesControllerPreviewKindTest < ActiveSupport::TestCase
  def kind(name) = FilesController.new.send(:preview_kind, name)

  # THE TEST THAT CATCHES A COPY, and the one to mutate. It NAMES extensions, so shrinking
  # TEXT_ROLES turns it red — where the derived sweep at the bottom of this file, whose subject
  # comes from TEXT_ROLES itself, would go on passing over a smaller set.
  #
  # It is also the regression guard for the collapse: this literal IS the inline list preview_kind
  # carried before, frozen. Five of its entries — xml log ini cfg conf — were in no ROLE_BY_EXT
  # entry at all, so deriving the branch from roles without wiring them first would have silently
  # taken the text preview away from files that already had one. Frozen is the point: it is the
  # OLD vocabulary, and re-deriving it from the new one would assert nothing.
  PREVIOUSLY_TEXT = %w[txt md markdown csv json xml yml yaml log rb js ts py rs go
                       c h cpp html css toml ini cfg conf sh gcode].freeze

  test "no extension lost the text preview it already had" do
    PREVIOUSLY_TEXT.each { |ext| assert_equal :text, kind("file.#{ext}"), ext }
  end

  # The widening, stated so it is read as intended rather than as fallout. Six extensions arrive
  # with the `code` role (cc hpp ino lua sql cmake), and four more come along for free because
  # deriving from ROLES takes the WHOLE gcode role rather than the single `gcode` extension the
  # old list named — a .nc from a CAM post is g-code text and now reads as such instead of
  # offering nothing but a download.
  test "the code role and the rest of the gcode family now preview as text" do
    %w[util.cc shim.hpp sketch.ino plot.lua schema.sql rules.cmake
       pocket.nc job.tap part.ngc slice.gco].each do |name|
      assert_equal :text, kind(name), name
    end
  end

  # THE NEIGHBOURING BRANCHES, WHICH MUST KEEP WINNING. Measure, image and pdf return BEFORE the
  # text branch and each is a richer preview that would be LOST, not gained, if text reached those
  # files first. `:model3d` returns after it, so it is the one the sweep below could never speak
  # for: a text role wrongly given to a mesh extension takes the 3D viewer away silently.
  test "the branches around :text still own their pages" do
    assert_equal :pdf,     kind("manual.pdf"), "pdf embeds the browser's own viewer"
    assert_equal :image,   kind("cover.png")
    assert_equal :measure, kind("panel.svg")
    assert_equal :model3d, kind("bracket.stl")
  end

  test "an unknown extension is still :other" do
    assert_equal :other, kind("mystery.qqq")
    assert_equal :other, kind("Makefile")
  end

  # TEXT_EXTS — ROLE AND CONTENT TYPE ARE DIFFERENT QUESTIONS, AND `.scad` ANSWERS THEM
  # DIFFERENTLY. OpenSCAD source files into `cad/` with the `.f3d` they generate and reads as
  # source code on the page. BOTH HALVES ARE THE TEST: the second one is what a careless fix
  # breaks, because the obvious way to make `.scad` text is to add `cad_source` to TEXT_ROLES —
  # which drags four BINARY formats along with it and renders them as mojibake on the main
  # deployment. Mutation-checked in exactly that direction.
  test "scad previews as text while its binary cad_source siblings do not" do
    assert_equal :text, kind("bracket.scad")

    %w[part.f3d body.fcstd flange.sldprt rig.sldasm].each do |name|
      assert_equal :other, kind(name),
                   "#{name} is a BINARY cad_source file — a text preview of it is mojibake"
    end
  end

  # THE NO-MIGRATION CLAIM, PINNED. TEXT_EXTS changes what a page RENDERS and nothing that is
  # STORED: `.scad` keeps the `cad_source` role RederiveVectorAndCadSourceRoles (2026-07-28)
  # already wrote into every existing attachment row, and keeps filing into `cad/`. That is the
  # whole reason this needed no re-derive migration of its own, so it is asserted rather than
  # asserted-in-a-comment — moving `scad` into ROLE_BY_EXT as `code` would turn both lines red and
  # WOULD need one.
  test "viewing scad as text did not move its role or its folder" do
    assert_equal "cad_source", Maker::FileAttachment.role_for("bracket.scad")
    assert_equal "cad", Maker::ProjectFolders.folder_for("bracket.scad")
  end

  # EVERY ENTRY MUST BE DOING WORK. An extension whose role is already a text role reaches the
  # branch without this constant, so listing it here changes nothing and hides the fact that the
  # ROLE TABLE is what covers it — the beginning of the second list this whole collapse removed.
  test "TEXT_EXTS names nothing the role table already covers" do
    redundant = Maker::FileAttachment::TEXT_EXTS.select do |ext|
      Maker::FileAttachment::TEXT_ROLES.include?(Maker::FileAttachment::ROLE_BY_EXT[ext])
    end
    assert_empty redundant,
                 "these reach :text through their ROLE already; drop them from TEXT_EXTS"
  end

  # THE DERIVATION ASSERTED AS A PROPERTY: every extension whose role is a text role must actually
  # REACH the text branch. What derivation newly risks is not the mapping but the ORDER — measure,
  # image and pdf all return first — so wiring an extension one of them already claims into a text
  # role would silently keep it out of the text set, with the vocabulary and the page disagreeing.
  #
  # THIS TEST MOSTLY CANNOT CATCH A COPY, and the boundary is measured rather than argued: its
  # subject comes from TEXT_ROLES, so dropping ONE role (gcode) shrinks the sweep and it passes,
  # while the frozen literal above goes red on `gcode`. Only a wholesale collapse to %w[document]
  # fails it, and then through the size floor rather than the derivation. Catching a copy is the
  # literal's job.
  #
  # WHAT THIS TEST ALONE CATCHES is the ordering conflict: wiring `svg` into `code` fails here and
  # NOWHERE else in this file — the branch test above asks for :measure and still gets it.
  test "every extension with a text role reaches the text branch" do
    exts = Maker::FileAttachment::ROLE_BY_EXT
             .select { |_ext, role| Maker::FileAttachment::TEXT_ROLES.include?(role) }.keys
    assert_operator exts.size, :>, 20, "the sweep needs a subject"
    exts.each { |ext| assert_equal :text, kind("file.#{ext}"), ext }
  end
end
