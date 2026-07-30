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
    test "the role vocabulary is exactly these ten values" do
      assert_equal %w[cad_source document gcode image instructions laser model other source_archive vector],
                   Maker::FileAttachment::ROLES.sort
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
  end
end
