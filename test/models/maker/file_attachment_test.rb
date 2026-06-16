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
  end
end
