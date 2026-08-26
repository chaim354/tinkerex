# frozen_string_literal: true

# THE CATALOG BECOMES A VIEW OVER THE LIBRARY, so a Maker::Model now has to say where it came from.
#
# `origin` DEFAULTS TO "import" so every existing row is correct with no backfill -- every model
# that exists today came through models#new.
#
# `auto_node_id` IS A node_id AND NOT A PATH, unlike a shelf. Library::Reconciler's pairing by
# (content_hash, size) keeps a renamed node's node_id -- §14b's headline promise -- so renaming
# `3D Models/Enclosure` to `3D Models/Enclosure v2` keeps ONE catalog entry where a path key would
# abandon the old row and mint a second.
#
# `dismissed_at` IS WHY DELETING AN AUTO MODEL DOES NOT DESTROY IT. A destroyed row is recreated by
# the next sweep and the user deletes it again -- §14f's recorded fight-the-user failure, which on
# chunk_remote also costs a changelog entry per round.
class AddAutoCatalogToMakerModels < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_models, :origin, :string, null: false, default: "import"
    add_column :maker_models, :auto_node_id, :string
    add_column :maker_models, :dismissed_at, :datetime
    # Partial: only auto rows carry the key, and two import rows must both be allowed a NULL.
    add_index :maker_models, %i[user_id auto_node_id], unique: true,
              where: "auto_node_id IS NOT NULL", name: "index_maker_models_on_auto_node_id"

    add_column :users, :shelves_seeded_at, :datetime
  end
end
