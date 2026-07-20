require "test_helper"

module Maker
  module Addons
    class LibraryOutputTest < ActiveSupport::TestCase
      include ActiveJob::TestHelper

      setup do
        @user = User.create!(email: "lo-#{SecureRandom.hex(4)}@example.com")
        Storage::ChunkStore.reset!
        if ENV["LIBRARY_BACKEND"] == "s3"
          require_relative "../../../support/fake_s3"
          @fake = FakeS3.new
          FileLayer.current = FileLayer::S3.new(bucket: "b", region: "us-east-1", access_key_id: "ak",
                                                secret_access_key: "sk", prefix: "library",
                                                client: @fake.client)
        end
      end
      teardown { FileLayer.reset! }

      test "writes a bundle of mixed-type files and ties each to the state" do
        state = @user.maker_addon_states.create!(addon_key: "boxes", name: "Box A", data: {})
        files = [
          { name: "boxa.svg", bytes: "<svg/>".b, content_type: "image/svg+xml", role: "output" },
          { name: "boxa.params.json", bytes: '{"x":100}'.b, content_type: "application/json", role: "parameters" }
        ]

        result = Maker::Addons::LibraryOutput.write(user: @user, state:, parent_node_id: nil, files:)

        assert_equal 2, result.length
        state.reload
        assert_equal %w[output parameters], state.files.map(&:role)
        state.files.each do |af|
          assert @user.nodes.exists?(node_id: af.node_id), "node #{af.node_id} must exist in the library"
        end
        assert_operator enqueued_jobs.count { |j| j[:job] == Maker::GeneratePreviewJob }, :>=, 1
      end
    end
  end
end
