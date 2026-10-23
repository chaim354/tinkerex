# THE CALCULATOR'S OLD ONE-TOOL FLAG GOES (2026-10-23). `users.pinned_tools` replaced it in
# 20261022180000, which copied every pin across, and User has ignored it since — so the containers
# this deploy replaces neither read it nor write it on INSERT, which is what makes the drop safe
# now and was not in the same deploy (that migration says why). Verified before writing this:
# every Unraid destination runs 647139bf (#468) or later (tinkerex#479), and OVH's last recorded
# image, b4c68e4e, predates the column, so its next deploy adds, copies and drops it in one run.
class RemoveCalculatorPinnedFromUsers < ActiveRecord::Migration[8.1]
  def change
    remove_column :users, :calculator_pinned, :boolean, null: false, default: false
  end
end
