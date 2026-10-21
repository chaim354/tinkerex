require "test_helper"

module Maker
  class ModelIntakeJobTest < ActiveJob::TestCase
    setup do
      @user = User.create!(email: "mij-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    # THE BACKEND GATE LIVES ON THE FAN-OUT, NOT ON #perform -- Library::ScanJob's own comment has
    # the argument: a SCHEDULE may no-op, but a COMMAND naming a user must not silently do nothing.
    test "the scheduled fan-out declines on a scannable backend" do
      use_fresh_share_library!

      assert_no_enqueued_jobs { Maker::ModelIntakeJob.sweep_all! }
    end

    # THE POSITIVE CONTROL FOR THE ASSERTION ABOVE, and it is not decoration: `assert_no_enqueued_jobs`
    # passes just as happily over a `sweep_all!` that returns unconditionally, or over a harness
    # that is not observing enqueues at all. Only this arm can tell "the gate declined" from "the
    # fan-out never worked". Mirrors project_intake_job_test.rb, which carries the same pair.
    test "the scheduled fan-out enqueues on a non-scannable backend" do
      FileLayer.current = FileLayer::ChunkRemote.new

      assert_enqueued_with(job: Maker::ModelIntakeJob, args: [ { user_id: @user.id } ]) do
        Maker::ModelIntakeJob.sweep_all!
      end
    end

    # #perform CARRIES NO GATE, so an explicit caller gets the sweep on any backend -- driven
    # through `.new.perform` rather than perform_now precisely to bypass the ActiveJob wrapper and
    # leave only the method under test.
    #
    # NO SHELF IS SET UP HERE, because none can be: the library root is one of
    # Maker::ModelIntake::SHELVES, built in since 2026-10-20, so a loose file at the root is its own
    # model for every user from the first sweep.
    test "perform sweeps even on a scannable backend when a caller names a user" do
      use_fresh_share_library!
      @user.nodes.create!(node_id: "f-1", name: "a.stl", kind: "file", mtime: 1, size: 1)

      Maker::ModelIntakeJob.new.perform(user_id: @user.id)

      assert_equal 1, @user.maker_models.count
    end

    # perform_now, NOT `.new.perform`: discard_on is applied by ActiveJob's wrapper, so calling the
    # method directly raises RecordNotFound and this test would fail for a reason that says nothing
    # about the declaration it exists to pin. Mutation-checked -- deleting `discard_on` turns it RED.
    test "a deleted user is discarded rather than recorded as a failure" do
      assert_nothing_raised { Maker::ModelIntakeJob.perform_now(user_id: 0) }
    end

    teardown { FileLayer.reset! }
  end
end
