# THE CALCULATOR'S SIDEBAR PIN (2026-10-21; docs/superpowers/plans/2026-10-21-calculator-modal.md,
# decision 1). A column, not a preferences table: it is one flag and there is no preferences
# mechanism to join. Server-side, so it follows the maker to every device — unlike the rail's
# collapse state, a per-browser cookie because it is about the screen, not the person.
class AddCalculatorPinnedToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :calculator_pinned, :boolean, null: false, default: false
  end
end
