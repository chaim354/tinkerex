# THE REVERSE DIRECTION. The existing [addon_state_id, node_id] composite answers "which files does
# this state own"; nothing indexed "which state produced this node", which is what the Files page
# asks for a whole page of nodes at once (Maker::AddonOrigin). A composite index can only be probed
# by a LEADING PREFIX of its columns, so an addon_state_id-first one cannot serve a node_id-only
# lookup. Measured on 20,000 rows, the lookup Maker::AddonOrigin issues:
#
#     without this index   SCAN maker_addon_files
#     with it              SEARCH maker_addon_files USING INDEX index_maker_addon_files_on_node_id
#
# One scan per page render, against a table that grows with every addon save the library has ever
# taken. Maker::AddonOrigin's own comment records why the lookup is shaped so that this index is
# actually REACHED — the obvious single-statement join does not reach it.
#
# NOT UNIQUE. Two states can hold a row for one node: a save that answers the 409 with
# `overwrite: "1"` rewrites a node another state produced, and Maker::Addons::LibraryOutput leaves
# the older state's row in place deliberately (it is the only record that that state produced the
# file). A unique index would turn that into a 500 at the save door.
class AddNodeIdIndexToMakerAddonFiles < ActiveRecord::Migration[8.1]
  def change
    add_index :maker_addon_files, :node_id
  end
end
