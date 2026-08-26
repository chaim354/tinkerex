require "test_helper"

module Maker
  class ProjectDiscoveryJobTest < ActiveJob::TestCase
    setup do
      @user = User.create!(email: "pdj-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
    end

    def dir(node_id, name, parent)
      @user.nodes.create!(node_id:, name:, kind: "dir", parent_node_id: parent, mtime: 1, size: 0)
    end

    # THE BACKEND GATE LIVES ON THE FAN-OUT, NOT ON #perform — Library::ScanJob's own comment has
    # the argument: a SCHEDULE may no-op, but a COMMAND naming a user must not silently do nothing.
    test "the scheduled fan-out declines on a scannable backend" do
      pin_file_layer_backend("share")
      FileLayer.current = FileLayer::Share.new(root: Dir.mktmpdir("pdj"))

      assert_no_enqueued_jobs { Maker::ProjectDiscoveryJob.sweep_all! }
    end

    # THE POSITIVE CONTROL FOR THE ASSERTION ABOVE, and it is not decoration:
    # `assert_no_enqueued_jobs` passes just as happily over a `sweep_all!` that returns
    # unconditionally, or over a harness not observing enqueues at all. Only this arm tells "the
    # gate declined" from "the fan-out never worked".
    test "the scheduled fan-out enqueues on a non-scannable backend" do
      FileLayer.current = FileLayer::ChunkRemote.new

      assert_enqueued_with(job: Maker::ProjectDiscoveryJob, args: [ { user_id: @user.id } ]) do
        Maker::ProjectDiscoveryJob.sweep_all!
      end
    end

    # #perform CARRIES NO GATE, so an explicit caller gets the sweep on any backend.
    test "perform sweeps on a scannable backend too" do
      pin_file_layer_backend("share")
      FileLayer.current = FileLayer::Share.new(root: Dir.mktmpdir("pdj"))
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "Desk Lamp", "d-projects")

      run = Maker::ProjectDiscoveryJob.new.perform(user_id: @user.id)

      assert_equal 1, run.created
      assert_equal "Desk Lamp", @user.maker_projects.sole.name
    end

    # THE CHAIN. Without it a chunk_remote user waits a SECOND 15-minute tick between "the folder
    # became a project" and "its files got attached and filed".
    test "a run that created something chains the intake on a non-scannable backend" do
      FileLayer.current = FileLayer::ChunkRemote.new
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "Desk Lamp", "d-projects")

      assert_enqueued_with(job: Maker::ProjectIntakeJob, args: [ { user_id: @user.id } ]) do
        Maker::ProjectDiscoveryJob.new.perform(user_id: @user.id)
      end
    end

    test "a run that created nothing chains nothing" do
      FileLayer.current = FileLayer::ChunkRemote.new
      dir("d-projects", "Projects", nil)

      assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
        run = Maker::ProjectDiscoveryJob.new.perform(user_id: @user.id)
        assert_equal 0, run.created, "precondition: this run must genuinely have created nothing"
      end
    end

    # GATED ON !scannable? AND THAT GATE IS NOT OPTIONAL. On share/s3 Library::ScanJob already
    # sequences discovery -> intake -> catalog inside ONE perform. A second, unsequenced filer is
    # the §14f scan-overlap bug: a move made after the Scanner captured its observations is paired
    # back by (content_hash, size), leaving the node at a path with no bytes and a download
    # returning a TERMINAL 404.
    test "the chain does not fire on a scannable backend" do
      pin_file_layer_backend("share")
      FileLayer.current = FileLayer::Share.new(root: Dir.mktmpdir("pdj"))
      dir("d-projects", "Projects", nil)
      dir("d-lamp", "Desk Lamp", "d-projects")

      assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
        run = Maker::ProjectDiscoveryJob.new.perform(user_id: @user.id)
        assert_equal 1, run.created, "precondition: the run must have created something to chain"
      end
    end

    test "a deleted user is discarded rather than failed" do
      assert_nothing_raised do
        Maker::ProjectDiscoveryJob.perform_now(user_id: 0)
      end
    end

    teardown { FileLayer.reset! }
  end
end
