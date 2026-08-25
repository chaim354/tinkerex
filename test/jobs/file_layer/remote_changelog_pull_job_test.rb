# frozen_string_literal: true

require "test_helper"

module FileLayer
  # Arc B, gap (a): ChangelogSync had exactly one caller, ChunkRemote#refresh!, itself reached only
  # from THIS app's own writes (mkdir/move/delete/undelete/finalize_upload) -- so a node another
  # device pushed straight to the sync server was invisible in the maker UI indefinitely, and
  # GET /files never refreshed the mirror as a side effect of a plain read. This job is the
  # recurring per-user pull that closes it.
  class RemoteChangelogPullJobTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    # Answers an EMPTY changelog -- enough for ChangelogSync#call to complete (one
    # full_resync_if_gapped probe + one page GET, both reporting nothing to apply) without touching
    # a real network. Matches ChangelogSyncTest::FakeTransport / RefreshAfterWriteTest's shape.
    class FakeTransport
      attr_reader :calls

      def initialize = (@calls = [])

      def get(path, params = {})
        @calls << [ :get, path, params ]
        { "changes" => [], "head_seq" => 0, "oldest_seq" => 1, "nodes" => [], "next_after_id" => 0 }
      end
    end

    # The "sync server is unreachable" double, for the propagation tests below.
    class RaisingTransport
      def get(*) = raise FileLayer::FetchError, "sync server unreachable"
    end

    setup { FileLayer.reset! }
    teardown { FileLayer.reset! }

    def create_user(tag)
      User.create!(email: "rcpj-#{tag}-#{SecureRandom.hex(4)}@example.com",
                   password: "correct horse battery staple", confirmed_at: Time.current)
    end

    # --- #perform: the command, ungated -----------------------------------------------------

    test "perform pulls the changelog for the given user" do
      user = create_user("a")
      transport = FakeTransport.new

      RemoteChangelogPullJob.perform_now(user_id: user.id, transport:)

      assert_includes transport.calls.map { |c| c[1] }, "/v1/changes",
                       "perform must call through to ChangelogSync, which pulls /v1/changes"
    end

    # #perform HAS NO GATE -- Library::ScanJob's own rule (scan_job.rb:14-20): a `return unless`
    # inside #perform would make an operator's (or a caller's) explicit run silently do nothing,
    # which is the exact failure mode the gate below exists to avoid at the FAN-OUT instead.
    test "perform has no gate and pulls even when the ambient backend is not chunk_remote" do
      user = create_user("b")
      transport = FakeTransport.new

      RemoteChangelogPullJob.perform_now(user_id: user.id, transport:)

      assert_includes transport.calls.map { |c| c[1] }, "/v1/changes"
    end

    # A raising pull must reach Solid Queue as a failed execution, not be swallowed -- matching
    # Library::ScanJob's "an unsafe scan is reported, not swallowed" (scan_job_test.rb). Swallowing
    # it here would hide an operator-visible signal (a downed sync server, an expired token) behind
    # silence; the schedule's own next tick is the retry, per ScanJob's own argument.
    test "a raising pull is not swallowed" do
      user = create_user("c")

      assert_raises(FileLayer::FetchError) do
        RemoteChangelogPullJob.perform_now(user_id: user.id, transport: RaisingTransport.new)
      end
    end

    # The user can be deleted between pull_all!'s fan-out and this running -- same shape as
    # Library::ScanJob / Maker::ProjectIntakeJob (GeneratePreviewJob sets the precedent).
    test "a deleted user is discarded, not failed" do
      assert_nothing_raised do
        perform_enqueued_jobs { RemoteChangelogPullJob.perform_later(user_id: -1) }
      end
    end

    # --- .pull_all!: the schedule, gated to chunk_remote ------------------------------------
    #
    # THE GATE, ASSERTED BOTH WAYS -- "a gate asserted in one direction is half a gate" (this
    # task's own rule; CLAUDE.md §15 makes the same point about ArchitectureInvariantsTest).

    test "pull_all! enqueues one job per user when the backend is chunk_remote" do
      user = create_user("d1")
      other = create_user("d2")
      FileLayer.current = FileLayer::ChunkRemote.new(transport: FakeTransport.new)

      assert_enqueued_jobs 2, only: RemoteChangelogPullJob do
        RemoteChangelogPullJob.pull_all!
      end
      assert_enqueued_with(job: RemoteChangelogPullJob, args: [ { user_id: user.id } ])
      assert_enqueued_with(job: RemoteChangelogPullJob, args: [ { user_id: other.id } ])
    end

    test "pull_all! enqueues nothing on chunk" do

      assert_no_enqueued_jobs(only: RemoteChangelogPullJob) { RemoteChangelogPullJob.pull_all! }
    end

    test "pull_all! enqueues nothing on share" do
      root = Dir.mktmpdir("rcpj-share")
      begin
        FileLayer.current = FileLayer::Share.new(root:)
        assert_no_enqueued_jobs(only: RemoteChangelogPullJob) { RemoteChangelogPullJob.pull_all! }
      ensure
        FileUtils.remove_entry(root)
      end
    end

    test "pull_all! enqueues nothing on s3" do
      FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                            secret_access_key: "sk")

      assert_no_enqueued_jobs(only: RemoteChangelogPullJob) { RemoteChangelogPullJob.pull_all! }
    end

    # ONE UNREACHABLE LIBRARY MUST NOT STOP THE SWEEP. pull_all! only ENQUEUES (perform_later), so
    # a user whose pull will later raise cannot prevent ANOTHER user's job from being enqueued --
    # each is an independent Solid Queue row, run independently. Pinned as its own test because it
    # is the property this job exists to guarantee, not a consequence to take on faith.
    test "one user's eventual failure does not stop another user's job from being enqueued or run" do
      doomed = create_user("e1")
      fine = create_user("e2")
      FileLayer.current = FileLayer::ChunkRemote.new(transport: FakeTransport.new)

      assert_enqueued_jobs 2, only: RemoteChangelogPullJob do
        RemoteChangelogPullJob.pull_all!
      end

      assert_raises(FileLayer::FetchError) do
        RemoteChangelogPullJob.perform_now(user_id: doomed.id, transport: RaisingTransport.new)
      end
      assert_nothing_raised do
        RemoteChangelogPullJob.perform_now(user_id: fine.id, transport: FakeTransport.new)
      end
    end
  end
end
