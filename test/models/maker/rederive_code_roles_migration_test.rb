require "test_helper"
require Dir[Rails.root.join("db/migrate/*_rederive_code_roles.rb")].first

# Drives the migration's up AND down against real rows rather than trusting it by reading.
#
# WHICH PREDECESSOR A REDERIVE MIGRATION COPIES IS INVISIBLE FROM READING IT, which is the reason
# rederive_laser_roles_migration_test.rb gives for existing. That one moves rows OUT of `vector`
# because `lbrn2` already had a role; this one is the FIRST TWO's shape, because all 26 code
# extensions were either brand new or mapped nowhere, so every row needing repair sits in "other".
# Copy the third here and `up` selects a role no row has and succeeds SILENTLY, while `down` files
# these rows under `vector` — somewhere they have never been. Neither is visible without driving it.
class RederiveCodeRolesMigrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rederive-code-#{SecureRandom.hex(4)}@example.com",
                         confirmed_at: Time.current, omniauth_signup: true)
    @project = @user.maker_projects.create!(name: "Firmware")
  end

  # node_id has no FK — the filename lives on the node, so the migration has to join to find it.
  def attach(name, role)
    node_id = "n-#{name}-#{SecureRandom.hex(2)}"
    @user.nodes.create!(node_id:, name:, kind: "file")
    @project.file_attachments.create!(user: @user, node_id:, role:)
  end

  def run_migration = ActiveRecord::Migration.suppress_messages { RederiveCodeRoles.new.up }
  def run_rollback  = ActiveRecord::Migration.suppress_messages { RederiveCodeRoles.new.down }

  # `conf` and `log` are two of the five extensions (xml log ini cfg conf) that had NO role at all
  # while the detail page previewed them as text — the rows likeliest to be sitting in "other".
  test "an other row pointing at a source file becomes code" do
    py    = attach("main.py", "other")
    ino   = attach("sketch.ino", "other")
    conf  = attach("nginx.conf", "other")
    log   = attach("serial.log", "other")

    run_migration

    assert_equal "code", py.reload.role
    assert_equal "code", ino.reload.role
    assert_equal "code", conf.reload.role
    assert_equal "code", log.reload.role
  end

  # THE SCOPE FROM THE OTHER SIDE. `where(role: "other")` must not become "every row" — a role
  # someone set deliberately is a decision, not a gap to fill.
  test "a role set deliberately is never re-derived" do
    filed = attach("build.log", "instructions")
    cover = attach("diagram.xml", "image")

    run_migration

    assert_equal "instructions", filed.reload.role
    assert_equal "image", cover.reload.role
  end

  test "an other row with no code mapping stays other" do
    txt = attach("readme.txt", "other")
    stl = attach("bracket.stl", "other")

    run_migration

    assert_equal "other", txt.reload.role
    assert_equal "other", stl.reload.role
  end

  test "a row whose node is gone is skipped, not crashed on" do
    orphan = ghost_attachment!(@project, user: @user, node_id: "ghost", role: "other")
    assert_nothing_raised { run_migration }
    assert_equal "other", orphan.reload.role
  end

  # THE HALF A COPIED RederiveLaserRoles GETS WRONG: its `down` returns rows to `vector`, which for
  # these rows is not a rollback but a move somewhere they have never been.
  test "down returns code rows to other" do
    py = attach("app.py", "other")
    run_migration
    assert_equal "code", py.reload.role

    run_rollback
    assert_equal "other", py.reload.role
  end

  test "running up twice is a no-op the second time" do
    py  = attach("app.py", "other")
    txt = attach("readme.txt", "other")

    run_migration
    run_migration

    assert_equal "code", py.reload.role
    assert_equal "other", txt.reload.role
  end

  # CODE_EXTS is a frozen COPY of what the model says — the migration's own comment names that cost
  # and accepts it. This is the same tripwire each predecessor carries for its own copied list, and
  # predecessor 1's is not decorative: it is what fired the moment `lbrn2` was remapped
  # `vector` -> `laser`. A frozen copy is only safe to keep BECAUSE something notices when it drifts.
  test "the migration's extension list still agrees with the model's" do
    assert_equal 26, RederiveCodeRoles::CODE_EXTS.size, "the list is the whole subject of this test"
    RederiveCodeRoles::CODE_EXTS.each do |ext|
      assert_equal RederiveCodeRoles::NEW_ROLE, Maker::FileAttachment::ROLE_BY_EXT[ext],
                   "migration maps #{ext} to code, model says " \
                   "#{Maker::FileAttachment::ROLE_BY_EXT[ext].inspect}"
    end
  end
end
