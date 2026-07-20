require "test_helper"

module Maker
  module Previews
    class EnqueueTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup { @user = User.create!(email: "enq@example.com") }

      test "creates a pending thumbnail preview and enqueues the job" do
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
        p = @user.maker_previews.find_by(node_id: "n1", version_id: "v1", kind: "thumbnail")
        assert_equal "pending", p.status
      end

      test "is idempotent: re-enqueuing a ready (node, version) does not enqueue again" do
        p = @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail", status: "ready")
        assert_no_enqueued_jobs do
          result = Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
          assert_equal p.id, result.id
        end
      end

      test "re-enqueues a previously failed preview" do
        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail", status: "failed")
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v1")
        end
      end

      test "a new version is a new preview row + a new job (supersede)" do
        @user.maker_previews.create!(node_id: "n1", version_id: "v1", kind: "thumbnail", status: "ready")
        assert_enqueued_with(job: Maker::GeneratePreviewJob) do
          Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.stl", version_id: "v2")
        end
        assert @user.maker_previews.exists?(node_id: "n1", version_id: "v2", kind: "thumbnail")
      end

      test "does nothing for a name with no registered renderer" do
        assert_no_enqueued_jobs do
          result = Maker::Previews::Enqueue.call(user: @user, node_id: "n1", name: "part.sldprt", version_id: "v1")
          assert_nil result
        end
        assert_not @user.maker_previews.exists?(node_id: "n1")
      end
    end
  end
end
