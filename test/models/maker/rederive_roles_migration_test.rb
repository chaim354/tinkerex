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
    orphan = ghost_attachment!(@project, user: @user, node_id: "gone", role: "other")
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
  #
  # ONE EXTENSION IS ALLOWED TO DISAGREE, and it is listed rather than skipped. `lbrn2` was remapped
  # `vector` -> `laser` when the laser role was added; this migration's snapshot stays frozen (its
  # own header forbids rewriting it — it must run against whatever the code looks like months from
  # now), and RederiveLaserRoles is what carries those rows forward instead.
  #
  # THE SECOND TEST IS WHAT STOPS THE EXCEPTION OUTLIVING ITS CAUSE — not a single assertion, and
  # not the first test, which only SKIPS entries in SUPERSEDED and never checks them again. Of the
  # second test's two assertions: the first catches SUPERSEDED's value drifting away from what the
  # model currently says (a third value, or lbrn2 remapped back without SUPERSEDED being updated);
  # the second catches SUPERSEDED's value being edited back into agreement with the frozen
  # predecessor instead of the entry being removed, at which point there is nothing left to
  # supersede. Without both, an entry here could stay valid forever, and the allowlist would
  # quietly become the drift it exists to catch.
  SUPERSEDED = { "lbrn2" => "laser" }.freeze

  test "the migration's extension list still agrees with the model's" do
    RederiveVectorAndCadSourceRoles::NEW_ROLE_BY_EXT.each do |ext, role|
      next if SUPERSEDED.key?(ext)

      assert_equal role, Maker::FileAttachment::ROLE_BY_EXT[ext],
                   "migration maps #{ext} to #{role}, model disagrees"
    end
  end

  test "every superseded extension really is superseded" do
    SUPERSEDED.each do |ext, role|
      assert_equal role, Maker::FileAttachment::ROLE_BY_EXT[ext],
                   "#{ext} is listed as superseded to #{role}, but the model says " \
                   "#{Maker::FileAttachment::ROLE_BY_EXT[ext].inspect} — update or replace its " \
                   "entry in SUPERSEDED"
      assert_not_equal role, RederiveVectorAndCadSourceRoles::NEW_ROLE_BY_EXT[ext],
                       "#{ext} no longer disagrees with the old migration — remove it from SUPERSEDED"
    end
  end
end
