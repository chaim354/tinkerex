# frozen_string_literal: true

# A SHELF IS A FOLDER THAT IS NOT ITSELF A MODEL -- its loose model-role files are each their own
# model and each of its subfolders is one model. See docs/invariants/model-intake.md.
#
# THE KEY IS A PATH PATTERN, NOT A node_id, and that is deliberate: the seeded
# `Projects/*/models` rule covers a folder per project, none of which need exist yet, and no
# node_id can express that. The cost -- a renamed folder silently stops matching -- is made
# visible in the settings UI rather than argued away.
class CreateMakerShelves < ActiveRecord::Migration[8.1]
  def change
    create_table :maker_shelves do |t|
      t.integer :user_id, null: false
      # "" is the library root. Segments joined by "/". One "*" per segment is a wildcard.
      t.string :path, null: false, default: ""
      t.timestamps
    end
    add_index :maker_shelves, %i[user_id path], unique: true
  end
end
