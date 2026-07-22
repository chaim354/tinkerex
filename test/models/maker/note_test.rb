require "test_helper"

module Maker
  class NoteTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "note-#{SecureRandom.hex(4)}@example.com") }

    test "valid with a user, node_id, and body" do
      note = @user.maker_notes.new(node_id: "n-1", body: "print at 0.2mm")
      assert note.valid?
    end

    test "requires node_id and body" do
      assert_not @user.maker_notes.new(node_id: "n-1", body: "").valid?
      assert_not @user.maker_notes.new(node_id: "", body: "hi").valid?
    end

    test "belongs to the user and is destroyed with them" do
      @user.maker_notes.create!(node_id: "n-1", body: "hi")
      assert_difference "Maker::Note.count", -1 do
        @user.destroy!
      end
    end
  end
end
