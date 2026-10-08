require "test_helper"

module Maker
  class PinTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "pin-#{SecureRandom.hex(4)}@example.com")
      @dir = @user.nodes.create!(node_id: "dir-a", name: "laser", kind: "dir")
    end

    test "a pin names a live folder in its own user's library" do
      assert @user.maker_pins.create(node_id: @dir.node_id).persisted?

      file = @user.nodes.create!(node_id: "file-a", name: "a.stl", kind: "file")
      refute @user.maker_pins.new(node_id: file.node_id).valid?, "a file is not a place"

      gone = @user.nodes.create!(node_id: "dir-gone", name: "old", kind: "dir", deleted: true)
      refute @user.maker_pins.new(node_id: gone.node_id).valid?, "a tombstoned folder cannot be pinned"

      other = User.create!(email: "other-#{SecureRandom.hex(4)}@example.com")
      other.nodes.create!(node_id: "dir-b", name: "theirs", kind: "dir")
      refute @user.maker_pins.new(node_id: "dir-b").valid?, "another user's folder is not yours to pin"
    end

    test "a folder is pinned once" do
      @user.maker_pins.create!(node_id: @dir.node_id)
      refute @user.maker_pins.new(node_id: @dir.node_id).valid?
    end

    test "pins take the next position, so the sidebar keeps the order they were pinned in" do
      b = @user.nodes.create!(node_id: "dir-c", name: "cnc", kind: "dir")
      first = @user.maker_pins.create!(node_id: @dir.node_id)
      second = @user.maker_pins.create!(node_id: b.node_id)
      assert_operator second.position, :>, first.position
      assert_equal [ first, second ], @user.maker_pins.ordered.to_a

      # `ordered` SORTS BY POSITION, NOT BY CREATION. Above, creation order and position agree, so
      # an `order(:id)` would pass too; give the later pin the LOWER position and it must lead.
      second.update_column(:position, first.position - 1)
      assert_equal [ second, first ], @user.maker_pins.ordered.to_a
    end

    test "the sidebar holds at most CAP pins" do
      Maker::Pin::CAP.times do |i|
        d = @user.nodes.create!(node_id: "cap-#{i}", name: "p#{i}", kind: "dir")
        @user.maker_pins.create!(node_id: d.node_id)
      end
      extra = @user.nodes.create!(node_id: "cap-extra", name: "one more", kind: "dir")
      pin = @user.maker_pins.new(node_id: extra.node_id)
      refute pin.valid?
      assert_match(/holds #{Maker::Pin::CAP}/, pin.errors.full_messages.to_sentence)
    end
  end
end
