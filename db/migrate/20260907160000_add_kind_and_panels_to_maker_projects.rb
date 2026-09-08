# THE PROJECT'S TYPE AND ITS PAGE'S LAYOUT (stage 4, S4-7; decision D4; stories 6.1-6.5).
#
# BOTH DEFAULTS REPRODUCE TODAY'S PAGE, which is stage 4's own rule (spec §4): `kind` is "other",
# whose preset hides nothing and reorders nothing, and `panels` is NULL, which Maker::ProjectKind
# reads as "no overrides". Running this migration on the three live deployments changes what
# nobody sees. Only a project created AFTER it — by Maker::ProjectDiscovery or by S4-6's adoption
# door — gets a suggested kind, and therefore a preset.
#
# NO INDEX ON EITHER, DELIBERATELY. `panels` is never a predicate: it is read off a row the page
# already loaded. `kind` is a predicate on exactly one page, /projects?kind=, which already
# materialises every one of the user's projects (`scope.order(updated_at: :desc).to_a`) and
# partitions them in Ruby — so an index buys nothing a WHERE over an already-loaded set does not,
# while costing a fourth btree write per project row beside the three `user_id`-led indexes this
# table already carries. It would also sit one step from architecture_invariants_test.rb's
# strict-prefix guard.
#
# `panels` IS NULLABLE RATHER THAN `default: {}`, for the reason `cover_node_id`'s own comment
# gives: nullable means "nobody has chosen", which is what every existing row means, and it keeps
# the forward run a pure DDL with no backfill. `Maker::ProjectKind.layout_for` reads nil and {}
# identically, so nothing downstream branches on which one it gets.
#
# `t.json` RUNS ON BOTH ADAPTERS — maker_addon_states.data and maker_sheets.data are already json
# on SQLite (self-host) and Postgres (managed), so this needs no adapter branch (§14e).
class AddKindAndPanelsToMakerProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_projects, :kind, :string, null: false, default: "other"
    add_column :maker_projects, :panels, :json
  end
end
