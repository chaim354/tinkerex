require "test_helper"
require Dir[Rails.root.join("db/migrate/*_delete_addon_parameters_file_rows.rb")].first

# Drives the migration's `up` against real rows rather than trusting it by reading.
#
# The assertion that matters most here is the NEGATIVE one: the migration must delete the join ROWS
# and leave the library FILES alone. That is the whole design decision (a user may have renamed,
# organized or attached those files, and a migration must not delete user bytes), it is the thing a
# later "tidy up the orphans too" change would break, and it is invisible in the SQL — which names
# only `maker_addon_files` and so looks harmless either way.
class DeleteAddonParametersFileRowsMigrationTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "addon-params-migration@example.com")
    @state = @user.maker_addon_states.create!(addon_key: "boxes", name: "My Box",
                                              data: { "generator" => "ABox", "params" => { "x" => "120" } })
    # A node per file, so "the file survived" is a real check and not a check on a row that never was.
    @user.nodes.create!(node_id: "n-out", name: "my-box-1.svg", kind: "file")
    @user.nodes.create!(node_id: "n-par", name: "my-box-1.params.json", kind: "file")
    @output = @state.files.create!(node_id: "n-out", role: "output",
                                  content_type: "image/svg+xml", position: 0)
    @params = @state.files.create!(node_id: "n-par", role: "parameters",
                                  content_type: "application/json", position: 1)
  end

  def run_migration
    ActiveRecord::Migration.suppress_messages { DeleteAddonParametersFileRows.new.up }
  end

  test "the parameters join row is deleted" do
    run_migration
    assert_not Maker::AddonFile.exists?(@params.id)
  end

  # The guard that keeps the migration from being a blunt instrument.
  test "the output join row survives" do
    run_migration
    assert Maker::AddonFile.exists?(@output.id), "the output row must not be swept with the parameters row"
    assert_equal %w[output], @state.reload.files.map(&:role)
  end

  # THE POINT OF THE WHOLE DESIGN: rows go, bytes stay.
  test "neither file is removed from the library" do
    run_migration
    assert @user.nodes.exists?(node_id: "n-par"),
           "the params FILE must survive — it is an ordinary library file the user may have organized"
    assert @user.nodes.exists?(node_id: "n-out")
    assert_not @user.nodes.find_by(node_id: "n-par").deleted?, "it must not be tombstoned either"
  end

  test "the state itself survives" do
    run_migration
    assert Maker::AddonState.exists?(@state.id)
  end

  # The spec's claim that a params file attached to a project stays visible in the project panel:
  # the attachment is a separate record, so losing the addon-bundle tie must not touch it.
  test "a project attachment on the params file is untouched" do
    project = @user.maker_projects.create!(name: "Desk Lamp")
    att = project.file_attachments.create!(user: @user, node_id: "n-par", role: "document")
    run_migration
    assert_equal "n-par", att.reload.node_id, "the project attachment must outlive the bundle tie"
  end

  test "down refuses — the rows cannot be reconstructed" do
    assert_raises(ActiveRecord::IrreversibleMigration) do
      ActiveRecord::Migration.suppress_messages { DeleteAddonParametersFileRows.new.down }
    end
  end

  # `up` must be re-runnable: a retried deploy runs it again, and a migration that errored on a
  # second pass would turn a routine retry into a failed one.
  test "running up twice is a no-op the second time" do
    run_migration
    assert_nothing_raised { run_migration }
    assert_equal %w[output], @state.reload.files.map(&:role)
  end
end
