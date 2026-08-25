require "test_helper"

module Maker
  class ProjectIntakeJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @user = User.create!(email: "pij-#{SecureRandom.hex(4)}@example.com",
                           confirmed_at: Time.current, omniauth_signup: true)
      @project = @user.maker_projects.create!(name: "Desk Lamp")
      @folder = @project.ensure_library_folder!(@user)
    end

    def file(name, parent: @folder.node_id)
      @user.nodes.create!(node_id: SecureRandom.uuid, name:, kind: "file",
                          parent_node_id: parent, size: 1, content_hash: SecureRandom.hex(8))
    end

    # --- the device-push nudge ---------------------------------------------------
    #
    # Closes §12.10: a file arriving through the MOUNT had no fast path and waited up to 15 minutes
    # for the periodic sweep, because a device push never nudged the way the three web upload doors
    # do. §12.10 rejected the obvious fix because Sync::Commit#finalize runs once PER FILE — 500
    # files would mean 500 synchronous sweeps. This ENQUEUES instead, and the job's own
    # limits_concurrency collapses the burst into one sweep. Asserting the enqueue rather than the
    # filing is what separates this design from the rejected one.
    test "a file landing at a project folder root enqueues a deferred sweep" do
      node = file("bracket.stl")

      assert_enqueued_with(job: Maker::ProjectIntakeJob, args: [ { user_id: @user.id } ]) do
        Maker::ProjectIntakeJob.nudge(user: @user, node:)
      end
    end

    # ROOT = INBOX IS THE WHOLE SORT RULE (§14f), so a file arriving deeper is already where someone
    # put it and there is nothing to file. This arm is what keeps the nudge off every commit in the
    # library — without it, every synced file anywhere would enqueue a sweep.
    test "a file landing deeper than the project root does NOT enqueue" do
      sub = @user.nodes.create!(node_id: SecureRandom.uuid, name: "cad", kind: "dir",
                                parent_node_id: @folder.node_id)
      node = file("part.step", parent: sub.node_id)

      assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
        Maker::ProjectIntakeJob.nudge(user: @user, node:)
      end
    end

    test "a file outside every project folder does NOT enqueue" do
      node = @user.nodes.create!(node_id: SecureRandom.uuid, name: "loose.stl", kind: "file",
                                 parent_node_id: nil, size: 1, content_hash: SecureRandom.hex(8))

      assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
        Maker::ProjectIntakeJob.nudge(user: @user, node:)
      end
    end

    # BEST-EFFORT: this runs inside the commit a device is waiting on, so nothing it does may fail
    # that commit. A nil node stands in for "the caller had nothing to give us".
    test "nudge never raises, whatever it is handed" do
      assert_nothing_raised { Maker::ProjectIntakeJob.nudge(user: @user, node: nil) }
    end

    test "perform attaches and files" do
      node = file("panel.svg")
      Maker::ProjectIntakeJob.perform_now(user_id: @user.id)
      assert @project.file_attachments.exists?(node_id: node.node_id)
      assert_equal "design", @user.nodes.find_by(node_id: node.reload.parent_node_id).name
    end

    # THE CAP REFUSAL'S ONLY RECORD. Maker::ProjectIntake.for_user logs nothing itself — it only
    # sets RunResult#status — so #report's `if run.status == :refused_too_many_moves` branch is the
    # SOLE place a refused sweep is ever written down anywhere. Pinned because it had ZERO coverage:
    # deleting that whole branch left every other test in this file green, since none of them push a
    # project over the cap. Without this test, a silently broken refusal log would mean a user's
    # projects could sit over-cap indefinitely with nothing anywhere to say so.
    test "the cap refusal is logged" do
      prior = ENV["PROJECT_ORGANIZE_MAX_MOVES"]
      ENV["PROJECT_ORGANIZE_MAX_MOVES"] = "1"
      file("a.svg")
      file("b.svg")

      log = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(log)
      begin
        Maker::ProjectIntakeJob.perform_now(user_id: @user.id)
      ensure
        Rails.logger = original_logger
        ENV["PROJECT_ORGANIZE_MAX_MOVES"] = prior
      end

      assert_match(/REFUSED to file 2 loose files for user #{@user.id} — over the 1 cap/, log.string)
    end

    # THE STEADY-STATE CASE, and the reason #report's zero-check exists at all: every 15 minutes,
    # forever, a project with nothing loose must print nothing — or a chunk deployment logs a row of
    # zeroes per project per quarter hour. `assert_empty log.string` does NOT work here: ActiveJob's
    # own Performing/Performed instrumentation writes to Rails.logger too, so an assertion on the
    # WHOLE log fails on noise this job never produced. Scoped instead to this job's own line shapes.
    test "a project with nothing to do logs nothing" do
      log = StringIO.new
      original_logger = Rails.logger
      Rails.logger = Logger.new(log)
      begin
        Maker::ProjectIntakeJob.perform_now(user_id: @user.id)
      ensure
        Rails.logger = original_logger
      end

      refute_match(/Maker::ProjectIntakeJob #{Regexp.escape(@project.slug)}:/, log.string)
      refute_match(/REFUSED/, log.string)
    end

    # The user can be deleted between the fan-out and this running. Nothing to sweep and nothing
    # wrong — discard rather than record a failure (GeneratePreviewJob sets the precedent).
    test "a missing user is discarded, not failed" do
      assert_nothing_raised do
        perform_enqueued_jobs do
          Maker::ProjectIntakeJob.perform_later(user_id: 999_999_999)
        end
      end
    end

    # THE GATE IS ON THE FAN-OUT, NOT ON #perform — the house rule Library::ScanJob states: a
    # `return unless` inside #perform would make an operator's explicit run silently do nothing.
    test "sweep_all! enqueues for a chunk deployment" do
      assert_enqueued_with(job: Maker::ProjectIntakeJob) do
        Maker::ProjectIntakeJob.sweep_all!
      end
    end

    # On a SCANNED backend Library::ScanJob is already the caller. Running both would reintroduce
    # the scan overlap the design places this call to prevent.
    test "sweep_all! declines on a scannable backend" do
      root = Dir.mktmpdir("pij-share")
      begin
        FileLayer.current = FileLayer::Share.new(root:)
        assert_no_enqueued_jobs(only: Maker::ProjectIntakeJob) do
          Maker::ProjectIntakeJob.sweep_all!
        end
      ensure
        FileLayer.reset!
        FileUtils.remove_entry(root)
      end
    end

    # #perform has NO gate, so an explicit run works on any backend.
    test "perform still performs on a scannable backend" do
      node = file("panel.svg")
      assert_nothing_raised { Maker::ProjectIntakeJob.perform_now(user_id: @user.id) }
      assert @project.file_attachments.exists?(node_id: node.node_id)
    end
  end
end
