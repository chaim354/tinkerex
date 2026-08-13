require "test_helper"

module Maker
  class AddonStateRevisionTest < ActiveSupport::TestCase
    setup do
      @user = User.create!(email: "rev@example.com")
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

    # NOT the immutability guard (that is `attr_readonly`, pinned below) — its absence blocks
    # nothing by itself. Asserted on the SCHEMA rather than on behaviour: a future `t.timestamps`
    # would compile and pass every other test here, and this is the one thing that would catch it.
    test "a revision has no updated_at" do
      assert_not Maker::AddonStateRevision.column_names.include?("updated_at")
    end

    # THE REAL GUARD. Confirmed empirically against this app's own config: `attr_readonly` makes a
    # rewrite through the model raise `ActiveRecord::ReadonlyAttributeError`, on assignment as well
    # as on `update!` — it does not wait for a failed save to say so. It is silent on a
    # relation-level `update_all` or raw SQL (neither instantiates a record), which is why the
    # migration's own backfill — the one legitimate writer — goes through `execute` rather than the
    # model.
    test "a revision refuses to be rewritten" do
      revision = @state.revisions.create!(revision: 1, data: @state.data)
      assert_raises(ActiveRecord::ReadonlyAttributeError) do
        revision.update!(data: { "generator" => "tray", "params" => { "h" => "999" } })
      end
      assert_equal "60", revision.reload.data.dig("params", "h")
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
