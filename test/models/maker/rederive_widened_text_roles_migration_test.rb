require "test_helper"
require Dir[Rails.root.join("db/migrate/*_rederive_widened_text_roles.rb")].first

# Drives the migration's up AND down against real rows rather than trusting it by reading.
#
# WHICH PREDECESSOR A REDERIVE MIGRATION COPIES IS INVISIBLE FROM READING IT — the reason every one
# of these tests exists. This one is the first two's shape in `up` (all 25 extensions mapped
# nowhere, so every row needing repair sits in "other") and NO predecessor's shape in `down`: the
# other four each introduced a role that did not exist before, so their blunt
# `where(role: NEW_ROLE).update_all(role: "other")` could only touch their own rows. This one
# widens `code` and `document`, which already hold every `.rb`, `.py`, `.txt` and `.md` in the
# library — so the blunt spelling is a rollback that destroys data it never touched on the way in.
# That is what the last two tests here are for, and neither is visible without driving it.
class RederiveWidenedTextRolesMigrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rederive-widened-#{SecureRandom.hex(4)}@example.com",
                         confirmed_at: Time.current, omniauth_signup: true)
    @project = @user.maker_projects.create!(name: "Firmware")
  end

  # node_id has no FK — the filename lives on the node, so the migration has to join to find it.
  def attach(name, role)
    node_id = "n-#{name}-#{SecureRandom.hex(2)}"
    @user.nodes.create!(node_id:, name:, kind: "file")
    @project.file_attachments.create!(user: @user, node_id:, role:)
  end

  def run_migration = ActiveRecord::Migration.suppress_messages { RederiveWidenedTextRoles.new.up }
  def run_rollback  = ActiveRecord::Migration.suppress_messages { RederiveWidenedTextRoles.new.down }

  test "an other row pointing at a source file becomes code" do
    java   = attach("Main.java", "other")
    tsx    = attach("App.tsx", "other")
    ps1    = attach("deploy.ps1", "other")
    vhd    = attach("top.vhd", "other")
    patch  = attach("fix.patch", "other")

    run_migration

    [ java, tsx, ps1, vhd, patch ].each { |a| assert_equal "code", a.reload.role, a.node_id }
  end

  test "an other row pointing at prose or tabular data becomes document" do
    rst = attach("README.rst", "other")
    tex = attach("paper.tex", "other")
    tsv = attach("cutlist.tsv", "other")

    run_migration

    [ rst, tex, tsv ].each { |a| assert_equal "document", a.reload.role, a.node_id }
  end

  # THE SCOPE FROM THE OTHER SIDE. `where(role: "other")` must not become "every row" — a role
  # someone set deliberately is a decision, not a gap to fill.
  test "a role set deliberately is never re-derived" do
    filed = attach("Main.java", "instructions")
    cover = attach("App.tsx", "image")

    run_migration

    assert_equal "instructions", filed.reload.role
    assert_equal "image", cover.reload.role
  end

  test "an other row with no mapping here stays other" do
    stl = attach("bracket.stl", "other")
    odd = attach("mystery.qqq", "other")

    run_migration

    assert_equal "other", stl.reload.role
    assert_equal "other", odd.reload.role
  end

  test "a row whose node is gone is skipped, not crashed on" do
    orphan = @project.file_attachments.create!(user: @user, node_id: "ghost", role: "other")
    assert_nothing_raised { run_migration }
    assert_equal "other", orphan.reload.role
  end

  test "down returns this migration's rows to other" do
    java = attach("Main.java", "other")
    rst  = attach("README.rst", "other")
    run_migration
    assert_equal "code", java.reload.role
    assert_equal "document", rst.reload.role

    run_rollback

    assert_equal "other", java.reload.role
    assert_equal "other", rst.reload.role
  end

  # THE HALF EVERY PREDECESSOR GETS WRONG IF COPIED, AND THE REASON `down` JOINS RATHER THAN
  # UPDATE_ALLing. These rows were filed by EARLIER migrations and by `role_for` itself; a blunt
  # `where(role: %w[code document]).update_all(role: "other")` returns all of them to "other" too —
  # green on every other test in this file, and a silent undo of all four predecessors.
  # Mutation-check by spelling `down` that way: these assertions are the only ones that go red.
  test "down leaves rows this migration never moved alone" do
    rb  = attach("app.rb", "code")       # RederiveCodeRoles' population
    txt = attach("notes.txt", "document") # RederiveDocumentRoles' population

    run_migration
    run_rollback

    assert_equal "code", rb.reload.role, "a .rb row is not this migration's to roll back"
    assert_equal "document", txt.reload.role, "a .txt row is not this migration's to roll back"
  end

  test "running up twice is a no-op the second time" do
    java = attach("Main.java", "other")
    stl  = attach("bracket.stl", "other")

    run_migration
    run_migration

    assert_equal "code", java.reload.role
    assert_equal "other", stl.reload.role
  end

  # NEW_ROLE_BY_EXT is a frozen COPY of what the model says — the migration's own comment names
  # that cost and accepts it. This is the same tripwire each predecessor carries for its own copied
  # list, and predecessor 1's is not decorative: it is what fired the moment `lbrn2` was remapped
  # `vector` -> `laser`. A frozen copy is only safe to keep BECAUSE something notices it drifting.
  test "the migration's extension map still agrees with the model's" do
    assert_equal 25, RederiveWidenedTextRoles::NEW_ROLE_BY_EXT.size,
                 "the map is the whole subject of this test"
    RederiveWidenedTextRoles::NEW_ROLE_BY_EXT.each do |ext, role|
      assert_equal role, Maker::FileAttachment::ROLE_BY_EXT[ext],
                   "migration maps #{ext} to #{role}, model says " \
                   "#{Maker::FileAttachment::ROLE_BY_EXT[ext].inspect}"
    end
  end
end
