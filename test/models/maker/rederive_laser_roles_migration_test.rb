require "test_helper"
require Dir[Rails.root.join("db/migrate/*_rederive_laser_roles.rb")].first

# Drives the migration's up AND down against real rows rather than trusting it by reading.
#
# THIS MIGRATION IS NOT ITS PREDECESSORS. Both earlier rederive migrations moved rows OUT OF
# "other" (they added new extensions), so they select role: "other" and their `down` returns rows
# to "other". lbrn2 already had a role, so this one moves vector -> laser and must roll back to
# vector. Copying a predecessor gives a no-op `up` and a `down` that puts the rows somewhere worse
# than where they started, and neither failure is visible without driving it.
class RederiveLaserRolesMigrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rederive-laser-#{SecureRandom.hex(4)}@example.com",
                         confirmed_at: Time.current, omniauth_signup: true)
    @project = @user.maker_projects.create!(name: "Lamp")
  end

  # node_id has no FK — the filename lives on the node, so the migration has to join to find it.
  def attach(name, role)
    node_id = "n-#{name}-#{SecureRandom.hex(2)}"
    @user.nodes.create!(node_id:, name:, kind: "file")
    @project.file_attachments.create!(user: @user, node_id:, role:)
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages { RederiveLaserRoles.new.up }
  end

  def run_rollback
    ActiveRecord::Migration.suppress_messages { RederiveLaserRoles.new.down }
  end

  test "a vector row pointing at a lbrn2 file becomes laser" do
    att = attach("box.lbrn2", "vector")
    run_migration
    assert_equal "laser", att.reload.role
  end

  # THE HALF A COPIED PREDECESSOR GETS WRONG. Selecting role: "other" finds nothing at all.
  test "it looks in vector, not other" do
    att = attach("tray.lbrn2", "vector")
    run_migration
    assert_equal "laser", att.reload.role,
                 "the migration must select role: 'vector' — lbrn2 already had a role"
  end

  test "svg and dxf rows are left alone" do
    svg = attach("panel.svg", "vector")
    dxf = attach("panel.dxf", "vector")
    run_migration
    assert_equal "vector", svg.reload.role
    assert_equal "vector", dxf.reload.role
  end

  test "a row whose node is gone is skipped, not crashed on" do
    att = @project.file_attachments.create!(user: @user, node_id: "ghost", role: "vector")
    assert_nothing_raised { run_migration }
    assert_equal "vector", att.reload.role
  end

  # THE OTHER HALF. A copied `down` sends these to "other" — worse than where they started.
  test "down returns laser rows to vector" do
    att = attach("case.lbrn2", "vector")
    run_migration
    run_rollback
    assert_equal "vector", att.reload.role
  end

  test "up is idempotent" do
    att = attach("lid.lbrn2", "vector")
    run_migration
    run_migration
    assert_equal "laser", att.reload.role
  end

  # LASER_EXTS is a frozen COPY of what the model says — the migration's own comment names that
  # cost and accepts it. This is the SAME TRIPWIRE the two predecessor migrations each carry for
  # their own copied lists, and it is not decorative: predecessor 1's copy of this exact test is
  # what fired the moment lbrn2 was remapped `vector` -> `laser`, which is the whole reason this
  # migration and Step 0's SUPERSEDED allowlist exist. A frozen copy is only safe to keep BECAUSE
  # something notices when it drifts — without this test, the next extension remapped into or out
  # of `laser` would drift silently, the same way lbrn2 almost did.
  test "the migration's extension list still agrees with the model's" do
    RederiveLaserRoles::LASER_EXTS.each do |ext|
      assert_equal RederiveLaserRoles::NEW_ROLE, Maker::FileAttachment::ROLE_BY_EXT[ext],
                   "migration maps #{ext} to laser, model disagrees"
    end
  end
end
