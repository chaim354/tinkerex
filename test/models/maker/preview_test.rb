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

    # ONE ROW PER (user, node, kind), NOT PER VERSION (§14b): the second row carries a DIFFERENT
    # version_id and is still a duplicate, which is the half that pins the key — a row per version
    # leaked a row and a blob on every save.
    test "uniqueness on node_id+kind, scoped to user, whatever the version" do
      @user.maker_previews.create!(node_id: "n", version_id: "v", kind: "thumbnail")
      dup = @user.maker_previews.build(node_id: "n", version_id: "v2", kind: "thumbnail")
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

    # THE STATUS CLASSES, ASKED OF EVERY STATUS WITH AND WITHOUT AN ASSET (F-S08-2). One table,
    # because the classes overlap on purpose — `rebuilding` is in flight AND showable, and only
    # `ready` is the current build — so a predicate that drifted on one status leaves every other
    # line here green. The first assertion makes a status added later fail until it is classified.
    test "each status lands in its classes, and only a row with an asset has anything to show" do
      #                 in_flight showable current_build failed      (asset attached)
      expected = {
        "pending"     => [ true,  false, false, false ],
        "processing"  => [ true,  false, false, false ],
        "rebuilding"  => [ true,  true,  false, false ],
        "ready"       => [ false, true,  true,  false ],
        "failed"      => [ false, false, false, true  ],
        "unsupported" => [ false, false, false, false ]
      }
      assert_equal Maker::Preview::STATUSES.sort, expected.keys.sort, "a status this table does not classify"

      expected.each do |status, classes|
        row = @user.maker_previews.create!(node_id: "a-#{status}", status:)
        row.asset.attach(io: StringIO.new("PNGDATA"), filename: "t.png", content_type: "image/png")
        assert_equal classes, [ row.in_flight?, row.showable?, row.current_build?, row.failed? ],
                     "#{status} with an asset"

        bare = @user.maker_previews.create!(node_id: "b-#{status}", status:)
        assert_not bare.showable?, "#{status} with no asset has no picture to show"
        assert_not bare.current_build?, "#{status} with no asset is no build at all"
      end
    end
  end
end
