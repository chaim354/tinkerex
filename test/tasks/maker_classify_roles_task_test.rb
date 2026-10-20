require "test_helper"
require "rake"

# `rake maker:classify_roles` — the operator's immediate run of the daily role sweep, for the day a
# deploy widens ROLE_BY_EXT and nobody wants to wait for the schedule. The task-loading idiom is
# projects_sweep_pointers_test.rb's: load the definitions once per process (a second load appends a
# second action), and re-enable after each invoke so a later invoke is not skipped as "already run".
class MakerClassifyRolesTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("maker:classify_roles")
    @task = Rake::Task["maker:classify_roles"]
    @task.reenable
  end

  teardown { @task&.reenable }

  test "the operator's run classifies now what the daily sweep would, and says how many" do
    user = User.create!(email: "classify-task-#{SecureRandom.hex(4)}@example.com")
    user.nodes.create!(node_id: "gerber", name: "top.gbr", kind: "file", mtime: 1, size: 1)
    att = user.maker_projects.create!(name: "Board").file_attachments
              .create!(user:, node_id: "gerber", role: "other")

    out, = capture_io { @task.invoke }

    assert_equal "pcb", att.reload.role
    assert_match(/\b1 attachment role/, out)
  end
end
