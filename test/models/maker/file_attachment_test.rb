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

    test "laser and vector extensions derive the vector role" do
      assert_equal "vector", Maker::FileAttachment.role_for("panel.svg")
      assert_equal "vector", Maker::FileAttachment.role_for("Panel.DXF")
      assert_equal "vector", Maker::FileAttachment.role_for("cut file.lbrn2")
    end

    test "CAD source extensions derive the cad_source role" do
      assert_equal "cad_source", Maker::FileAttachment.role_for("box.scad")
      assert_equal "cad_source", Maker::FileAttachment.role_for("Bracket.f3d")
      assert_equal "cad_source", Maker::FileAttachment.role_for("frame.FCStd")
    end

    test "the existing derivations are unchanged" do
      assert_equal "model", Maker::FileAttachment.role_for("bracket.stl")
      assert_equal "image", Maker::FileAttachment.role_for("photo.jpg")
      assert_equal "instructions", Maker::FileAttachment.role_for("manual.pdf")
      assert_equal "gcode", Maker::FileAttachment.role_for("print.gcode")
      assert_equal "source_archive", Maker::FileAttachment.role_for("bundle.zip")
      assert_equal "other", Maker::FileAttachment.role_for("readme.txt")
      assert_equal "other", Maker::FileAttachment.role_for("no-extension")
    end

    # The invariant that keeps a display heading from ever naming a role that isn't valid.
    test "every role has a label and every label is a role" do
      assert_equal Maker::FileAttachment::ROLES.sort,
                   Maker::FileAttachment::ROLE_LABELS.keys.sort
    end

    test "the two new roles are accepted by the validation" do
      %w[vector cad_source].each do |role|
        att = @item.file_attachments.build(user: @user, node_id: "n", role:)
        assert att.valid?, "expected #{role} to be a valid role"
      end
    end
  end
end
