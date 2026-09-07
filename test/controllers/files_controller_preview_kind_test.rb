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

  # THE `:model3d` BRANCH, DERIVED FROM THE ONE VOCABULARY since 2026-09-06 — the same collapse the
  # `:text` branch got, and for the same reason: ModelsController#show offers the SAME viewer off
  # the SAME constant, so a literal here would let the file page and the model page disagree about
  # which of a model's files are viewable. NAMED rather than swept, so shrinking VIEWABLE_3D_EXTS
  # turns this red where a derived sweep over that constant would go on passing over a smaller set
  # (the argument PREVIOUSLY_TEXT above makes for itself).
  test "every format the 3D viewer can open reaches the :model3d branch" do
    %w[bracket.stl part.3mf widget.obj scene.gltf scene.glb scan.ply mesh.off rig.dae world.wrl
       old.3ds char.fbx surf.3dm print.amf cad.step cad.stp cad.iges cad.igs solid.brep
       body.fcstd].each { |name| assert_equal :model3d, kind(name), name }
  end

  # THE FOUR THE ENGINE READS AND THIS APP STILL DOES NOT OFFER, each for its own stated reason
  # (Maker::FileAttachment::VIEWABLE_3D_EXTS names all four). `.svg` is the one that matters most:
  # it IS importable, and `:measure` returning first is what keeps the Measure view its page — so
  # this asserts the ORDER as much as the list.
  test "the formats deliberately left out of the viewer keep the pages they had" do
    assert_equal :measure, kind("panel.svg"), "the Measure view owns .svg, and returns first"
    assert_equal :other,   kind("building.ifc"), "web-ifc is MPL-2.0 and is not shipped"
    assert_equal :other,   kind("model.bim"),    "not a maker format"
    assert_equal :other,   kind("solid.brp"),    "one spelling per format; .brep is the one"
  end

  # A ROLE IS WHERE A FILE FILES, NOT WHETHER IT RENDERS — the split `.scad` already carries, now
  # in the other direction. `.fcstd` is VIEWABLE and stays `cad_source`, so it keeps filing into
  # `cad/` beside the `.f3d` it sits next to; making it a `model` would MOVE it on the user's NAS.
  test "viewing a FreeCAD project in 3D did not move its role or its folder" do
    assert_equal :model3d, kind("body.fcstd")
    assert_equal "cad_source", Maker::FileAttachment.role_for("body.fcstd")
    assert_equal "cad", Maker::ProjectFolders.default_folder_for("body.fcstd")
  end

  # THE `:gerber` BRANCH (tracespace). Every one of these is plain ASCII and `.gbrjob` is JSON, so
  # each would read as `:text` if this branch were removed or reordered below the text one — which
  # is a preview that is correct about the bytes and useless about the board. The three families are
  # named separately because they arrive from different tools: an RS-274X layer, an Excellon drill
  # file, and the job manifest.
  test "Gerber layers, drill files and the job manifest preview as :gerber" do
    %w[board.gbr top.gtl bottom.gbl mask.gts silk.gto paste.gtp outline.gko
       mech.gm1 plane.gp1 inner.g1 guide.gg1].each { |name| assert_equal :gerber, kind(name), name }
    assert_equal :gerber, kind("board.drl"), "Excellon (KiCad, Altium)"
    assert_equal :gerber, kind("board.xln"), "Excellon (Eagle)"
    assert_equal :gerber, kind("board.gbrjob"), "the job file is the board's manifest, not a document"
  end

  # THE BRANCH IS DERIVED FROM THE ONE VOCABULARY, and this is the assertion that says so: adding a
  # `pcb` extension to `ROLE_BY_EXT` must need no edit to `FilesController`. The size floor keeps it
  # from going vacuous if the role were ever emptied (§14e).
  test "every extension with the pcb role reaches the gerber branch" do
    exts = Maker::FileAttachment::ROLE_BY_EXT.select { |_ext, role| role == "pcb" }.keys
    assert_operator exts.size, :>, 20, "the sweep needs a subject"
    assert_equal exts.sort, FilesController::GERBER_EXTS.sort
    exts.each { |ext| assert_equal :gerber, kind("board.#{ext}"), ext }
  end

  # THE ROLE IS NOT A TEXT ROLE, AND THAT IS THE BELT BEHIND THE BRANCH'S BRACES. Adding `pcb` to
  # TEXT_ROLES would register a TextThumb renderer for every layer and put a source viewer one
  # reordering away from the board — asserted on the CONSTANT because `preview_kind` returns
  # `:gerber` first and would stay green through exactly that mistake.
  #
  # THE THIRD LINE READ `assert_nil Registry.for("gtl")` UNTIL 2026-09-07, and the weakening is the
  # point rather than a concession — the same move `.fcstd`'s case above records. Its claim has
  # always been "no TEXT renderer claims a Gerber layer"; it could say `nil` only because Gerbers
  # had no renderer at all. They have one now (tracespace under node), so the old spelling asserted
  # a second, unrelated fact that this slice deliberately changed. Both halves are kept separately,
  # so neither is lost the next time one moves.
  test "the pcb role is not a text role" do
    assert_not_includes Maker::FileAttachment::TEXT_ROLES, "pcb"
    assert_not Maker::FileAttachment.text?("board.gtl")
    assert_not_equal Maker::Previews::TextThumb, Maker::Previews::Registry.for("gtl"),
                     "a source thumbnail of a Gerber layer is a picture of its ASCII, not its board"
    assert_equal Maker::Previews::Gerber, Maker::Previews::Registry.for("gtl")
  end

  # A GERBER LAYER'S PAGE IS STILL THE VIEWER, NOT THE THUMBNAIL, AND THE ORDER IS WHAT SAYS SO.
  # `:gerber` returns several branches before `:thumbnail`, so registering a renderer for every pcb
  # extension (2026-09-07) changed the GRID cell and the poster and left the page's owner alone —
  # the same "a poster, not a replacement" relationship `:model3d` has with `stl`/`3mf`/`obj`.
  test "a Gerber layer keeps the :gerber page now that it also has a thumbnail" do
    assert_equal :gerber, kind("top.gtl")
    assert_not_nil Maker::Previews::Registry.for("gtl"), "…and the grid cell is no longer blank"
  end

  # A ZIP REACHES `:thumbnail` BY NAME, AND THE BOARD BRANCH IS A READ. `Maker::Previews::GerberZip`
  # claims `zip`, so `preview_kind` — which is NAME-ONLY for the whole vocabulary — now answers
  # `:thumbnail` for every zip. That is not the page a Gerber export gets: `FilesController#show`
  # overrides `@kind` to `:gerber` after `Maker::GerberArchive` has actually looked inside, which is
  # the one preview kind decided by content. A zip of firmware keeps the name-only answer, and its
  # preview row terminates `unsupported` after one bounded read.
  test "a zip previews as :thumbnail by name, and only a read makes it a board" do
    assert_equal :thumbnail, kind("firmware.zip")
    assert_equal :thumbnail, kind("Gerber_board.zip")
    assert_equal Maker::Previews::GerberZip, Maker::Previews::Registry.for("zip")
  end

  # `Makefile` WAS THE SECOND CASE HERE AND HAD TO MOVE, which is worth recording rather than
  # quietly swapping: it stood for "no extension, therefore no preview", and since 2026-08-26 that
  # inference is exactly what TEXT_BASENAMES removes — a Makefile is plain text and now previews as
  # such. The CLAIM this test makes is unchanged, so it keeps an extensionless name that is
  # genuinely not in that set; substituting one that IS would make the test agree with itself.
  test "an unknown extension is still :other" do
    assert_equal :other, kind("mystery.qqq")
    assert_equal :other, kind("firmware")
  end

  # STORY 2.3: `.ai` said "No inline preview for this file type." because nothing claimed it. It
  # takes the `:thumbnail` branch now — the last branch before `:other`, reached because
  # Registry.for("ai") finally answers. NOT `:pdf`: that branch embeds the bytes for the browser's
  # own viewer, which a browser handed a file named `.ai` downloads instead of rendering.
  test "an Illustrator file previews as a thumbnail rather than as nothing" do
    assert_equal :thumbnail, kind("logo.ai")
    assert_equal :other, kind("logo.eps"), "and nothing else moved with it"
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
      assert_not_equal :text, kind(name),
                       "#{name} is a BINARY cad_source file — a text preview of it is mojibake"
    end
  end

  # THE ASSERTION ABOVE WAS `assert_equal :other` UNTIL 2026-09-06, AND THE WEAKENING IS THE POINT
  # rather than a concession. Its claim has always been "these must not read as TEXT"; it happened
  # to be able to say `:other` because none of the four had any preview at all. `.fcstd` now has
  # one — the OpenCascade importer reads a FreeCAD project — so the old spelling asserted a second,
  # unrelated fact (that it has no viewer) that the slice deliberately changed. Both halves are
  # kept, separately, so neither can be lost the next time one of the four gains a preview.
  test "the binary cad_source siblings still have exactly the previews they should" do
    assert_equal :model3d, kind("body.fcstd"), "FreeCAD projects open in the 3D viewer"
    %w[part.f3d flange.sldprt rig.sldasm].each do |name|
      assert_equal :other, kind(name), "#{name} has no reader in any engine this app ships"
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
    assert_equal "cad", Maker::ProjectFolders.default_folder_for("bracket.scad")
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

  # THE CROSS-LAYER CLAIM, AND THE BUG EVERY OTHER TEST IN THIS FILE SAT BESIDE WITHOUT SEEING.
  # `preview_kind` was collapsed onto the one vocabulary on 2026-08-25. `Maker::Previews::Registry`
  # was NOT — it went on hand-listing four text extensions (txt md markdown json) — so 33 of the 37
  # extensions this file asserts are `:text` had NO GRID THUMBNAIL: `Enqueue.call` returns nil for
  # a name no renderer claims, so no row is ever created and the cell stays blank forever.
  #
  # EVERY TEST ABOVE PASSED THROUGHOUT, and the reason is worth naming rather than just fixing:
  # they all ask what the DETAIL page renders, and the missing half was the GRID. Two layers, one
  # question, and no test spanned them — which is the same shape as the `scope:` form bugs in
  # §14d, where the assertion was true and simply about the wrong thing.
  #
  # THE SIZE FLOOR IS LOAD-BEARING. Without it a derivation that collapsed to `[]` satisfies this
  # sweep perfectly — §14e's vacuous-guard shape, which this repo has shipped twice.
  test "every filename that previews as :text also has a thumbnail renderer" do
    exts = Maker::FileAttachment::TEXT_EXTENSIONS
    assert_operator exts.size, :>, 50, "the sweep needs a subject"
    exts.each do |ext|
      assert_equal :text, kind("file.#{ext}"), ext
      assert_not_nil Maker::Previews::Registry.for(ext),
                     ".#{ext} previews as text but nothing renders it — a blank cell in the grid"
    end
  end

  # EXTENSIONLESS TEXT. `File.extname("LICENSE")` is `""` and so is `File.extname(".gitignore")`,
  # so NO entry in an extension table can reach these — they answered `:other` and rendered
  # "No inline preview for this file type." over plain text. The live share library holds
  # LICENSE x6, Makefile/makefile x7 and README x3.
  #
  # BOTH CASES OF `Makefile` ARE THE TEST, not decoration: the library really contains both
  # spellings, so a predicate that forgot to downcase would pass on one and fail on the other.
  test "extensionless text files preview as text" do
    %w[LICENSE LICENCE Makefile makefile README CHANGELOG Dockerfile Rakefile
       .gitignore .editorconfig .clang-format].each do |name|
      assert_equal :text, kind(name), name
    end
  end

  # THE OTHER HALF, AND WHAT KEEPS THE BASENAME LIST FROM BECOMING "anything without a dot".
  # An extensionless BINARY exists and rendering it as text is mojibake — the same argument that
  # keeps `.f3d` out of TEXT_EXTS. Absence from the list must stay a real answer.
  test "an unlisted extensionless name is still not text" do
    %w[firmware blob a.out mystery].each do |name|
      assert_equal :other, kind(name), name
    end
  end

  # A BASENAME MATCH MUST ALSO REACH A RENDERER, or the file previews as text on the detail page
  # and shows a blank grid cell — the exact split this arc's first half existed to close, and one
  # `Registry.for_filename` reintroduces for these names unless it asks about basenames too.
  test "extensionless text files also resolve to a thumbnail renderer" do
    %w[LICENSE Makefile README .gitignore].each do |name|
      assert_equal Maker::Previews::TextThumb, Maker::Previews::Registry.for_filename(name), name
    end
  end

  # `Registry.for` TAKES AN EXTENSION AND MUST NOT GAIN THE BASENAME FALLBACK. Only the filename
  # door holds a filename; teaching the extension door to also answer for "LICENSE" would let a
  # caller holding a genuine extension match a basename by coincidence.
  test "the raw extension door does not answer for a basename" do
    assert_nil Maker::Previews::Registry.for("license")
    assert_nil Maker::Previews::Registry.for("makefile")
  end

  # THE ROLE IS DELIBERATELY UNCHANGED, so these files do not MOVE on the user's NAS. Same split
  # `.scad` carries: role answers "where does this file live", content type answers "how do we show
  # it". Making LICENSE a `document` would file it into `docs/` — a change to their files, which
  # nobody asked for.
  #
  # MUTATION-CHECK BY TEACHING `role_for` ABOUT `TEXT_BASENAMES`, which is the realistic way this
  # gets undone (one plausible line: `return "document" if TEXT_BASENAMES.include?(...)`). Adding
  # "license" to ROLE_BY_EXT does NOT work and was the first thing tried: that hash is keyed by
  # EXTENSION, and `LICENSE` has none, so the entry is unreachable from `role_for` — it reddens a
  # different test entirely, by making `Registry.for("license")` resolve. Recorded because a
  # mutation that cannot express the defect proves nothing about the guard.
  test "previewing an extensionless text file did not move its role or its folder" do
    assert_equal "other", Maker::FileAttachment.role_for("LICENSE")
    assert_equal "other", Maker::ProjectFolders.default_folder_for("LICENSE")
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
