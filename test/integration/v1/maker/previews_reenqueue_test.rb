require "test_helper"

module V1
  module Maker
    # Behavioral gaps in PreviewsController#create's re-enqueue logic:
    #   - re-POSTing a FAILED preview resets it to pending and re-enqueues the job.
    #   - re-POSTing a READY/processing preview does NOT reset or re-enqueue (idempotent).
    class PreviewsReenqueueTest < ActionDispatch::IntegrationTest
      setup do
        @token = bootstrap_token(email: "reenq@example.com", device_name: "laptop")
        @user  = User.find_by(email: "reenq@example.com")
      end
      def auth(t) = { "Authorization" => "Bearer #{t}" }

      test "re-POSTing a failed preview resets it to pending and re-enqueues the render" do
        preview = @user.maker_previews.create!(node_id: "n.svg", version_id: "v1",
                                               kind: "thumbnail", status: "failed",
                                               error: "boom")

        assert_enqueued_with(job: ::Maker::GeneratePreviewJob) do
          post "/v1/maker/previews",
               params: { preview: { node_id: "n.svg", version_id: "v1", kind: "thumbnail" } },
               as: :json, headers: auth(@token)
        end

        assert_response :ok # existing record => not :created
        assert_equal "pending", preview.reload.status
        assert_equal 1, @user.maker_previews.where(node_id: "n.svg").count
      end

      test "re-POSTing a READY preview does NOT reset status or enqueue a job" do
        preview = @user.maker_previews.create!(node_id: "ok.svg", version_id: "v1",
                                               kind: "thumbnail", status: "ready")

        assert_no_enqueued_jobs(only: ::Maker::GeneratePreviewJob) do
          post "/v1/maker/previews",
               params: { preview: { node_id: "ok.svg", version_id: "v1", kind: "thumbnail" } },
               as: :json, headers: auth(@token)
        end

        assert_response :ok
        assert_equal "ready", preview.reload.status
      end

      test "re-POSTing an unsupported preview is left terminal (no reset, no enqueue)" do
        preview = @user.maker_previews.create!(node_id: "x.sldprt", version_id: "v1",
                                               kind: "thumbnail", status: "unsupported",
                                               error: "no renderer")

        assert_no_enqueued_jobs(only: ::Maker::GeneratePreviewJob) do
          post "/v1/maker/previews",
               params: { preview: { node_id: "x.sldprt", version_id: "v1", kind: "thumbnail" } },
               as: :json, headers: auth(@token)
        end

        assert_response :ok
        assert_equal "unsupported", preview.reload.status
      end
    end
  end
end
