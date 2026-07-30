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
        # `thumbnail` is deliberately a role NO ADDON EMITS. The point of this test is that
        # LibraryOutput is role-agnostic — it never inspects the bytes or the role — and a role the
        # app has never heard of proves that better than a real one, which could pass by coincidence.
        # (It used to be `parameters`, back when every addon wrote a `.params.json` beside its output.
        # That file was removed 2026-07-29 — `Maker::AddonState#data` is the record — so keeping the
        # word here would have left a fixture naming a concept the app no longer has.)
        files = [
          { name: "boxa.svg", bytes: "<svg/>".b, content_type: "image/svg+xml", role: "output" },
          { name: "boxa-thumb.png", bytes: "\x89PNG".b, content_type: "image/png", role: "thumbnail" }
        ]

        result = Maker::Addons::LibraryOutput.write(user: @user, state:, parent_node_id: nil, files:)

        assert_equal 2, result.length
        state.reload
        assert_equal %w[output thumbnail], state.files.map(&:role)
        state.files.each do |af|
          assert @user.nodes.exists?(node_id: af.node_id), "node #{af.node_id} must exist in the library"
        end
        assert_operator enqueued_jobs.count { |j| j[:job] == Maker::GeneratePreviewJob }, :>=, 1
      end
    end
  end
end
