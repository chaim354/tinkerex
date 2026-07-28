require "test_helper"
require Dir[Rails.root.join("db/migrate/*_rederive_vector_and_cad_source_roles.rb")].first

class RederiveRolesMigrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rederive@example.com")
    @project = @user.maker_projects.create!(name: "Lamp")
  end

  # node_id has no FK — the filename lives on the node, so the migration has to join to find it.
  def attach(name, role)
    @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file")
    @project.file_attachments.create!(user: @user, node_id: "n-#{name}", role:)
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages do
      RederiveVectorAndCadSourceRoles.new.up
    end
  end

  test "an 'other' dxf becomes vector and an 'other' scad becomes cad_source" do
    dxf  = attach("panel.dxf", "other")
    scad = attach("box.scad", "other")
    # SolidWorks travels with Fusion — if this list ever drifts from ROLE_BY_EXT, closing the gap
    # after this migration has run needs a whole second migration, so it is pinned here too.
    sld  = attach("mount.sldprt", "other")

    run_migration

    assert_equal "vector", dxf.reload.role
    assert_equal "cad_source", scad.reload.role
    assert_equal "cad_source", sld.reload.role
  end

  test "a role set deliberately by the importer is never re-derived" do
    # A PDF the model-library importer marked `instructions`; also a .dxf someone filed as
    # `instructions` on purpose. Neither is "other", so neither is touched.
    pdf = attach("manual.pdf", "instructions")
    odd = attach("diagram.dxf", "instructions")

    run_migration

    assert_equal "instructions", pdf.reload.role
    assert_equal "instructions", odd.reload.role
  end

  test "an 'other' row with no new mapping stays other" do
    txt = attach("readme.txt", "other")
    run_migration
    assert_equal "other", txt.reload.role
  end

  test "an attachment whose node is missing is left alone rather than raising" do
    orphan = @project.file_attachments.create!(user: @user, node_id: "gone", role: "other")
    assert_nothing_raised { run_migration }
    assert_equal "other", orphan.reload.role
  end

  test "down returns the new roles to other" do
    dxf = attach("panel.dxf", "other")
    run_migration
    assert_equal "vector", dxf.reload.role

    ActiveRecord::Migration.suppress_messages { RederiveVectorAndCadSourceRoles.new.down }
    assert_equal "other", dxf.reload.role
  end

  test "running up twice is a no-op the second time" do
    dxf = attach("panel.dxf", "other")
    txt = attach("readme.txt", "other")

    run_migration
    run_migration

    assert_equal "vector", dxf.reload.role
    assert_equal "other", txt.reload.role
  end

  # The migration deliberately COPIES its extension list rather than referencing ROLE_BY_EXT, so the
  # two can silently drift. This is the only thing that would notice.
  test "the migration's extension list still agrees with the model's" do
    RederiveVectorAndCadSourceRoles::NEW_ROLE_BY_EXT.each do |ext, role|
      assert_equal role, Maker::FileAttachment::ROLE_BY_EXT[ext],
                   "migration maps #{ext} to #{role}, model disagrees"
    end
  end
end
