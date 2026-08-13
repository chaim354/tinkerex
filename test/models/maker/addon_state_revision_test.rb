require "test_helper"

module Maker
  class AddonStateRevisionTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "rev@example.com", password: "correct horse battery staple",
                           confirmed_at: Time.current)
      @state = @user.maker_addon_states.create!(
        addon_key: "boxes", name: "shelf box", data: { "generator" => "tray", "params" => { "h" => "60" } }
      )
    end

    test "a new state starts at revision 1" do
      assert_equal 1, @state.revision
    end

    test "revisions are unique per state" do
      @state.revisions.create!(revision: 1, data: @state.data)
      assert_raises(ActiveRecord::RecordNotUnique) do
        @state.revisions.insert!({ revision: 1, data: {}, created_at: Time.current })
      end
    end

    # A SNAPSHOT IS IMMUTABLE — there is no updated_at, so nothing can rewrite one and leave the
    # history disagreeing with itself. Asserted on the SCHEMA rather than on behaviour: a model
    # callback could be removed, a missing column cannot.
    test "a revision has no updated_at" do
      assert_not Maker::AddonStateRevision.column_names.include?("updated_at")
    end

    test "destroying a state destroys its revisions" do
      @state.revisions.create!(revision: 1, data: {})
      assert_difference -> { Maker::AddonStateRevision.count } => -1 do
        @state.destroy!
      end
    end

    # THE BACKFILL'S GUARANTEE, asserted as a property of the data rather than of the migration
    # file: every state has a revision-1 snapshot carrying the data it had at that moment. A state
    # created after the migration gets one from the save door (Task 2); one created here directly
    # does not, which is why this test seeds its own.
    test "a revision records the params as saved, not the state's later data" do
      @state.revisions.create!(revision: 1, data: @state.data)
      @state.update!(data: { "generator" => "tray", "params" => { "h" => "80" } }, revision: 2)
      @state.revisions.create!(revision: 2, data: @state.data)

      assert_equal "60", @state.revisions.find_by(revision: 1).data.dig("params", "h")
      assert_equal "80", @state.revisions.find_by(revision: 2).data.dig("params", "h")
    end
  end
end
