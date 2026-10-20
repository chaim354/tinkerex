require "test_helper"

module Maker
  class AddonStateTest < ActiveSupport::TestCase
    setup { @user = User.create!(email: "addon@example.com") }

    test "ties a bundle of files, ordered by position, cascading on destroy" do
      state = @user.maker_addon_states.create!(addon_key: "boxes", name: "My box",
                                               data: { generator: "ABox", params: { x: 100 } })
      # `thumbnail` is deliberately a role NO ADDON EMITS — the model is role-agnostic, and a role the
      # app has never heard of proves that better than a real one. (It used to be `parameters`, from
      # when every addon wrote a `.params.json` beside its output; that file was removed 2026-07-29.)
      state.files.create!(node_id: "n-svg", role: "output", content_type: "image/svg+xml", position: 0)
      state.files.create!(node_id: "n-thumb", role: "thumbnail", content_type: "image/png", position: 1)

      assert_equal %w[output thumbnail], state.reload.files.map(&:role)
      assert_equal "boxes", state.addon_key
      assert_equal 100, state.data["params"]["x"]

      assert_difference("Maker::AddonFile.count", -2) { state.destroy }
    end

    # THE LATEST SAVE'S FILES FIRST, IN SAVE ORDER, THEN THE ROWS EARLIER SAVES LEFT. A state keeps
    # the row of a file an earlier revision wrote and a later one stopped emitting
    # (Maker::Addons::LibraryOutput#upsert_file!), so `position` repeats across saves and only
    # `revision` says which save a row came from. The rows are created in an order that DISAGREES
    # with the order under test (the stale save first, and the current save's second file before its
    # first), so neither creation order nor the old (position, id) tiebreak can pass this.
    test "files list the latest save's outputs first, in save order, then earlier saves' rows" do
      state = @user.maker_addon_states.create!(addon_key: "boxes", name: "My box", data: {}, revision: 2)
      state.files.create!(node_id: "n-v1-a", role: "output", position: 0, revision: 1)
      state.files.create!(node_id: "n-v1-b", role: "output", position: 1, revision: 1)
      state.files.create!(node_id: "n-v2-b", role: "output", position: 1, revision: 2)
      state.files.create!(node_id: "n-v2-a", role: "output", position: 0, revision: 2)

      assert_equal %w[n-v2-a n-v2-b n-v1-a n-v1-b], state.reload.files.map(&:node_id)
    end

    test "requires addon_key and name" do
      s = Maker::AddonState.new(user: @user)
      assert_not s.valid?
      assert s.errors[:addon_key].present?
      assert s.errors[:name].present?
    end
  end
end
