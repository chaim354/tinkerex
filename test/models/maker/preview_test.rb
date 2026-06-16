require "test_helper"

module Maker
  class PreviewTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "prev@example.com") }

    test "valid with node_id + defaults" do
      p = @user.maker_previews.build(node_id: "n1")
      assert p.valid?
      assert_equal "thumbnail", p.kind
      assert_equal "pending",   p.status
    end

    test "node_id is required" do
      assert_not @user.maker_previews.build(node_id: nil).valid?
    end

    test "kind and status must be in the allowed sets" do
      assert_not @user.maker_previews.build(node_id: "n", kind: "bogus").valid?
      assert_not @user.maker_previews.build(node_id: "n", status: "bogus").valid?
    end

    test "unsupported is a valid status" do
      assert @user.maker_previews.build(node_id: "n", status: "unsupported").valid?
    end

    test "uniqueness on node_id+version_id+kind, scoped to user" do
      @user.maker_previews.create!(node_id: "n", version_id: "v", kind: "thumbnail")
      dup = @user.maker_previews.build(node_id: "n", version_id: "v", kind: "thumbnail")
      assert_not dup.valid?
    end

    test "same node/version/kind is allowed for a different user" do
      @user.maker_previews.create!(node_id: "n", version_id: "v", kind: "thumbnail")
      other = User.create!(email: "other@example.com")
      assert other.maker_previews.build(node_id: "n", version_id: "v", kind: "thumbnail").valid?
    end

    test "can attach an asset" do
      p = @user.maker_previews.create!(node_id: "n")
      p.asset.attach(io: StringIO.new("PNGDATA"), filename: "t.png", content_type: "image/png")
      assert p.asset.attached?
    end
  end
end
