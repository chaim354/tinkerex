require "test_helper"

module Maker
  class FileAttachmentTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "att@example.com")
      @item = @user.maker_items.create!(title: "Lamp")
    end

    test "attaches a file to an item by node_id" do
      att = @item.file_attachments.create!(
        user: @user, node_id: "node-123", role: "model"
      )
      assert_equal @item, att.attachable
      assert_equal "node-123", att.node_id
    end

    test "node_id is required" do
      att = @item.file_attachments.build(user: @user, node_id: nil)
      assert_not att.valid?
    end

    test "role must be in the allowed set" do
      att = @item.file_attachments.build(user: @user, node_id: "n", role: "bogus")
      assert_not att.valid?
    end

    test "destroying the item destroys its attachments" do
      @item.file_attachments.create!(user: @user, node_id: "n1")
      assert_difference -> { Maker::FileAttachment.count }, -1 do
        @item.destroy
      end
    end

    # lbrn2 moved to the laser role (see "lbrn2 is laser, not vector" below); svg/dxf stay vector.
    # Kept as its own test for the coverage the newer, plainer tests don't have: case-insensitivity
    # on the extension and a filename with a space.
    # THE ROLE AND THE BROWSER'S LIST ARE TWO LISTS (tinkerex#285): heic/tiff are images by role and
    # not inline; ico is inline and nobody's image; png is both. `preview_kind` is where the split
    # reaches the file page — a .heic gets the server thumbnail, a .png its own bytes.
    test "an iPhone original is an image by role and not a browser-inline image" do
      %w[IMG_0001.heic scan.tiff scan.tif shot.heif].each do |name|
        assert_equal "image", Maker::FileAttachment.role_for(name), "#{name} files as an image"
        assert_not Maker::FileAttachment.inline_image?(name), "#{name} is not browser-inline"
      end
      assert Maker::FileAttachment.inline_image?("lid.PNG")
      assert Maker::FileAttachment.inline_image?("favicon.ico")
      assert_equal "other", Maker::FileAttachment.role_for("favicon.ico")
      kind = Class.new { include FilePreview }.new
      assert_equal :thumbnail, kind.send(:preview_kind, "IMG_0001.heic")
      assert_equal :image, kind.send(:preview_kind, "lid.png")
    end

    test "vector and laser extensions derive their distinct roles" do
      assert_equal "vector", Maker::FileAttachment.role_for("panel.svg")
      assert_equal "vector", Maker::FileAttachment.role_for("Panel.DXF")
      assert_equal "laser", Maker::FileAttachment.role_for("cut file.lbrn2")
    end

    test "CAD source extensions derive the cad_source role" do
      assert_equal "cad_source", Maker::FileAttachment.role_for("box.scad")
      assert_equal "cad_source", Maker::FileAttachment.role_for("Bracket.f3d")
      assert_equal "cad_source", Maker::FileAttachment.role_for("frame.FCStd")
      assert_equal "cad_source", Maker::FileAttachment.role_for("mount.sldprt")
      assert_equal "cad_source", Maker::FileAttachment.role_for("Rig.SLDASM")
    end

    test "the existing derivations are unchanged" do
      assert_equal "model", Maker::FileAttachment.role_for("bracket.stl")
      assert_equal "image", Maker::FileAttachment.role_for("photo.jpg")
      assert_equal "instructions", Maker::FileAttachment.role_for("manual.pdf")
      assert_equal "gcode", Maker::FileAttachment.role_for("print.gcode")
      assert_equal "source_archive", Maker::FileAttachment.role_for("bundle.zip")
      assert_equal "document", Maker::FileAttachment.role_for("readme.txt")
      assert_equal "other", Maker::FileAttachment.role_for("no-extension")
    end

    # Pinned independently of ROLE_LABELS on purpose. Asserting ROLES == ROLE_LABELS.keys is
    # tautological — ROLES is DEFINED as those keys — so it cannot catch a typo'd key like
    # "cad_soruce", which is exactly the failure a reader assumes it guards. This literal can.
    # `cnc_design` joined in stage 4, S4-2, and this literal going red is what a new role is
    # SUPPOSED to cost: the count in the test name is part of the claim, so widening the vocabulary
    # is a decision someone typed here rather than one a derivation absorbed silently.
    test "the role vocabulary is exactly these thirteen values" do
      assert_equal %w[cad_source cnc_design code document gcode image instructions laser model other pcb source_archive vector],
                   Maker::FileAttachment::ROLES.sort
    end

    # THE `pcb` ROLE (the Gerber preview slice). Three families, one role — RS-274X layers, Excellon
    # drill files and the `.gbrjob` manifest — because a board house is handed one directory, and a
    # role is what puts them in one. Named rather than derived: a sweep over ROLE_BY_EXT would
    # assert the table equals itself.
    test "the fabrication formats carry the pcb role" do
      %w[board.gbr top.gtl bottom.gbl mask.gts silk.gbo paste.gtp outline.gko mech.gm1
         plane.gp2 inner.g3 guide.gg1 drill.drl drill.xln board.gbrjob].each do |name|
        assert_equal "pcb", Maker::FileAttachment.role_for(name), name
      end
    end

    # `.gbrjob` IS JSON AND IS STILL `pcb`, NOT `document`. It is part of the fabrication package,
    # so filing it into `docs/` would split one deliverable in two — the tripwire for someone
    # "correcting" it on the grounds that its bytes are JSON.
    test "the Gerber job file files with the board, not with the documents" do
      assert_equal "pcb", Maker::FileAttachment.role_for("board.gbrjob")
      assert_equal "pcb", Maker::ProjectFolders.default_folder_for("board.gbrjob")
    end

    test "the two new roles are accepted by the validation" do
      %w[vector cad_source].each do |role|
        att = @item.file_attachments.build(user: @user, node_id: "n", role:)
        assert att.valid?, "expected #{role} to be a valid role"
      end
    end

    # The extension set is DERIVED from what this app already believes, not invented here:
    # Maker::Previews::Registry already routes txt/md/markdown/json to TextThumb, and
    # FilesHelper::EXT_FAMILIES already grouped txt/md/csv as "Documents". This is the union.
    test "the document role covers the text formats the app already recognises" do
      %w[notes.txt readme.md readme.markdown data.json cutlist.csv].each do |name|
        assert_equal "document", Maker::FileAttachment.role_for(name), "expected #{name} to be a document"
      end
    end

    # THE 2026-08-26 WIDENING. These were text the app did not KNOW was text: `role_for` answered
    # "other", so they got no source viewer, no thumbnail and no filing. Named rather than derived
    # — a sweep over ROLE_BY_EXT would assert the table equals itself.
    test "the common source, build and prose formats now carry a role" do
      { "Main.java" => "code", "App.kt" => "code", "View.swift" => "code", "Program.cs" => "code",
        "index.php" => "code", "build.pl" => "code", "sim.jl" => "code", "plot.r" => "code",
        "App.jsx" => "code", "App.tsx" => "code", "App.vue" => "code", "App.svelte" => "code",
        "flash.bat" => "code", "deploy.ps1" => "code", "rules.mk" => "code",
        "build.gradle" => "code", "boot.asm" => "code", "vectors.s" => "code",
        "top.v" => "code", "top.vhd" => "code", "fix.diff" => "code", "fix.patch" => "code",
        "README.rst" => "document", "paper.tex" => "document", "cutlist.tsv" => "document"
      }.each { |name, role| assert_equal role, Maker::FileAttachment.role_for(name), name }
    end

    test "document is accepted by the validation" do
      att = @item.file_attachments.build(user: @user, node_id: "n", role: "document")
      assert att.valid?
    end

    # pdf STAYS `instructions`: Models::AttachmentsController dispatches ExtractPdfMetadataJob on
    # exactly that value, so folding pdf into `document` would silently stop PDF metadata
    # extraction. This test is the tripwire for that.
    test "pdf stays instructions, not document" do
      assert_equal "instructions", Maker::FileAttachment.role_for("manual.pdf")
    end

    # THE SPLIT THE FOLDER MAP NEEDS. svg/dxf/lbrn2 were all `vector`, so "laser" and "design" were
    # not distinguishable in the one place the app defines file types.
    test "lbrn2 is laser, not vector" do
      assert_equal "laser", Maker::FileAttachment.role_for("box.lbrn2")
    end

    test "svg and dxf stay vector" do
      assert_equal "vector", Maker::FileAttachment.role_for("panel.svg")
      assert_equal "vector", Maker::FileAttachment.role_for("panel.dxf")
    end

    # These had NO role at all before — a CNC-heavy project was entirely "Other".
    test "nc, tap and ngc are gcode" do
      %w[nc tap ngc].each do |ext|
        assert_equal "gcode", Maker::FileAttachment.role_for("part.#{ext}"), ext
      end
    end

    test "laser is a real role, so the inclusion validation accepts it" do
      assert_includes Maker::FileAttachment::ROLES, "laser"
      assert_equal "Laser", Maker::FileAttachment::ROLE_LABELS["laser"]
    end

    # PINNED ON PURPOSE: both the project attachments panel and the Files-page chips iterate
    # ROLE_LABELS in order, so where "laser" sits is a UI decision, not incidental hash order. The
    # split put it right after "vector" so the two 2D/laser categories render adjacent — the panel
    # section and the filter chip for one sit next to the other's. Asserting the adjacency rather
    # than freezing the whole ten-key order: a test that pins every position would fail on any
    # unrelated future insertion, which is noise rather than a guard.
    test "laser sits immediately after vector in ROLE_LABELS" do
      keys = Maker::FileAttachment::ROLE_LABELS.keys
      assert_equal keys.index("vector") + 1, keys.index("laser")
    end

    # Every extension must satisfy FilesController::EXT_RE or it renders a filter chip that links and
    # silently does nothing. The three new ones are short, but the rule is what matters.
    test "every extension satisfies the Files-page filter regex" do
      Maker::FileAttachment::ROLE_BY_EXT.each_key do |ext|
        assert_match FilesController::EXT_RE, ext, ext
      end
    end

    # pdf must NOT drift to `document`: Models::AttachmentsController dispatches
    # ExtractPdfMetadataJob on this exact value, so the column is behavioural.
    test "pdf is still instructions" do
      assert_equal "instructions", Maker::FileAttachment.role_for("guide.pdf")
    end

    # SOURCE CODE IS A ROLE, so a firmware tree files itself into `code/` instead of scattering
    # across `other/`. The names span the four families the role covers — C/C++ and Arduino,
    # scripting, systems languages, and the config/build formats that sit beside the code they
    # configure — because a role is worth exactly the extensions wired to it.
    test "source files resolve to the code role" do
      %w[main.cpp util.cc driver.h shim.hpp sketch.ino app.py helper.rb bundle.js types.ts
         lib.rs main.go flash.sh plot.lua schema.sql page.html site.css feed.xml serial.log
         config.toml platformio.ini app.cfg nginx.conf ci.yml deploy.yaml rules.cmake].each do |name|
        assert_equal "code", Maker::FileAttachment.role_for(name), name
      end
    end

    # TEXT_ROLES is what FilesController#preview_kind derives its :text branch from — the one
    # vocabulary, not a second extension list beside it (§14d). A role named here that ROLES does
    # not have would match nothing and fail SILENTLY: the branch goes on working and one file type
    # quietly loses its preview.
    test "TEXT_ROLES names only roles that exist" do
      assert_empty Maker::FileAttachment::TEXT_ROLES - Maker::FileAttachment::ROLES
    end

    # ASSERTED ON THE CONSTANT, because that is where the rule lives. Mutation-checked: adding
    # `instructions` to TEXT_ROLES leaves `preview_kind("manual.pdf") == :pdf` GREEN — the `:pdf`
    # branch returns before the text branch — and trips the derived sweep only as a contradiction
    # ("expected :text, got :pdf") that names the wrong culprit. What the mistake would really
    # change is every LATER reader of TEXT_ROLES: a pdf handed to a source-code viewer.
    test "instructions is not a text role" do
      assert_not_includes Maker::FileAttachment::TEXT_ROLES, "instructions"
    end

    # STAGE 4, S4-2 — THE THREE FORMATS THE BENCH ACTUALLY PRODUCES THAT THE VOCABULARY HAD NEVER
    # HEARD OF. All three had a full page and no role, so all three filed into `other/`: `.mage`
    # has Measure and a CNC operations panel, `.lbrn` has the LightBurn thumbnail and Measure
    # (Registry has claimed it since the Lbrn2 renderer landed), and `.ai` had nothing at all.
    # share, 2026-09-07: 23 .mage, 25 .ai.
    test "MillMage, LightBurn v1 and Illustrator files have roles" do
      assert_equal "cnc_design", Maker::FileAttachment.role_for("catan.mage")
      assert_equal "cnc_design", Maker::FileAttachment.role_for("CATAN5.MAGE")
      assert_equal "laser",      Maker::FileAttachment.role_for("tray.lbrn")
      assert_equal "vector",     Maker::FileAttachment.role_for("logo.ai")
    end

    # `cnc_design` IS NOT `gcode`, AND THE SPLIT IS THE POINT. `.nc`/`.tap`/`.ngc`/`.gcode` are the
    # machine's OUTPUT — the toolpath you send; a `.mage` is the PROJECT you go back and edit, the
    # CNC sibling of `.lbrn2`. They share a FOLDER (`cnc/`) because that is where a maker looks for
    # their CNC work, and they must not share a ROLE, because a role is also what
    # Maker::ModelIntake denies a model and what a panel heading reads.
    test "a MillMage project is not g-code" do
      assert_not_equal Maker::FileAttachment.role_for("catan.mage"),
                       Maker::FileAttachment.role_for("catan.nc")
      assert_equal "CNC design", Maker::FileAttachment::ROLE_LABELS.fetch("cnc_design")
      assert_includes Maker::FileAttachment::ROLES, "cnc_design"
    end

    # `.mage` IS NOT TEXT, though it is XML — its page is Measure, exactly like `.lbrn2`'s. The
    # guard is on the CONSTANT because preview_kind's `:measure` branch returns first and would
    # stay green if the role ever joined TEXT_ROLES (the argument `pcb` already carries here).
    test "the CNC design role is not a text role" do
      assert_not_includes Maker::FileAttachment::TEXT_ROLES, "cnc_design"
      refute Maker::FileAttachment.text?("catan.mage")
    end
  end
end
