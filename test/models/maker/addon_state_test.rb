require "test_helper"

module Maker
  class AddonStateTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "addon@example.com") }

    test "ties a bundle of files, ordered by position, cascading on destroy" do
      state = @user.maker_addon_states.create!(addon_key: "boxes", name: "My box",
                                               data: { generator: "ABox", params: { x: 100 } })
      state.files.create!(node_id: "n-svg", role: "output", content_type: "image/svg+xml", position: 0)
      state.files.create!(node_id: "n-params", role: "parameters", content_type: "application/json", position: 1)

      assert_equal %w[output parameters], state.reload.files.map(&:role)
      assert_equal "boxes", state.addon_key
      assert_equal 100, state.data["params"]["x"]

      assert_difference("Maker::AddonFile.count", -2) { state.destroy }
    end

    test "requires addon_key and name" do
      s = Maker::AddonState.new(user: @user)
      assert_not s.valid?
      assert s.errors[:addon_key].present?
      assert s.errors[:name].present?
    end
  end
end
