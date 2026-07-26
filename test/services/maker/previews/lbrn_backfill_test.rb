require "test_helper"

module Maker
  module Previews
    class LbrnBackfillTest < ActiveJob::TestCase
      def user = @user ||= User.create!(email: "bf@example.com", password: "correct horse battery staple", confirmed_at: Time.current)

      def preview_for(name, metadata: nil, kind: "thumbnail", status: "ready")
        nid = "node-#{name}"
        user.nodes.find_or_create_by!(node_id: nid) { |n| n.name = name; n.kind = "file" }
        Maker::Preview.create!(user:, node_id: nid, version_id: "v1", kind:, status:, metadata:)
      end

      test "re-enqueues only lightburn previews missing metadata" do
        needs = preview_for("a.lbrn2", metadata: nil)
        preview_for("b.lbrn2", metadata: { "app_version" => "1.7" })  # already has it -> skip
        preview_for("c.svg", metadata: nil)                            # not lightburn -> skip

        assert_enqueued_jobs 1, only: Maker::GeneratePreviewJob do
          Maker::Previews::LbrnBackfill.call
        end
        assert_enqueued_with(job: Maker::GeneratePreviewJob, args: [ needs.id ])
      end
    end
  end
end
