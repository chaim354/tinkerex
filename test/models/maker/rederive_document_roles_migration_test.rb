require "test_helper"
require Dir[Rails.root.join("db/migrate/*_rederive_document_roles.rb")].first

# Drives the migration's `up` against real rows rather than trusting it by reading.
class RederiveDocumentRolesMigrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "rederive-doc@example.com")
    @project = @user.maker_projects.create!(name: "Lamp")
  end

  # node_id has no FK — the filename lives on the node, so the migration has to join to find it.
  def attach(name, role)
    @user.nodes.create!(node_id: "n-#{name}", name:, kind: "file")
    @project.file_attachments.create!(user: @user, node_id: "n-#{name}", role:)
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages { RederiveDocumentRoles.new.up }
  end

  def run_rollback
    ActiveRecord::Migration.suppress_messages { RederiveDocumentRoles.new.down }
  end

  test "an other row pointing at a text file becomes a document" do
    att = attach("readme.txt", "other")
    run_migration
    assert_equal "document", att.reload.role
  end

  test "every document extension is re-derived" do
    atts = %w[a.txt b.md c.markdown d.json e.csv].map { |n| attach(n, "other") }
    run_migration
    atts.each { |a| assert_equal "document", a.reload.role, "#{a.node_id} was not re-derived" }
  end

  # The guard that keeps the migration from being a blunt instrument.
  test "an other row with no document extension is left alone" do
    att = attach("mystery.xyz", "other")
    run_migration
    assert_equal "other", att.reload.role
  end

  test "a row already in another role is untouched" do
    att = attach("bracket.stl", "model")
    run_migration
    assert_equal "model", att.reload.role
  end

  # An attachment whose node is gone has nothing to derive from and must not blow up the run.
  test "an attachment pointing at a missing node is skipped without raising" do
    att = @project.file_attachments.create!(user: @user, node_id: "n-missing", role: "other")
    assert_nothing_raised { run_migration }
    assert_equal "other", att.reload.role
  end

  test "down returns document rows to other" do
    att = attach("readme.txt", "other")
    run_migration
    run_rollback
    assert_equal "other", att.reload.role
  end

  # The migration deliberately COPIES its extension list rather than referencing ROLE_BY_EXT, so the
  # two can silently drift. This is the only thing that would notice — the same guard the
  # predecessor migration's test carries, and it is NOT redundant with the tests above: re-mapping
  # `csv` in the model while leaving the migration's frozen copy alone was verified to leave the
  # ENTIRE suite green, because every other test here derives its expectation from one side only.
  test "the migration's extension list still agrees with the model's" do
    RederiveDocumentRoles::NEW_ROLE_BY_EXT.each do |ext, role|
      assert_equal role, Maker::FileAttachment::ROLE_BY_EXT[ext],
                   "migration maps #{ext} to #{role}, model disagrees"
    end
  end

  # The predecessor pins this too. `up` is re-runnable by design (the mapping is a pure function of
  # the current filename), and a migration that double-counted or errored on a second pass would be
  # a real hazard on a retried deploy.
  test "running up twice is a no-op the second time" do
    att = attach("readme.txt", "other")
    run_migration
    run_migration
    assert_equal "document", att.reload.role
  end
end
