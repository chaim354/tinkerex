# A PREVIEW THE MAKER CHOSE (2026-10-20): "Use this view as preview" in the 3D viewer writes the
# thumbnail row with source "viewer", and Maker::Previews::Enqueue leaves such a row alone for as
# long as its content token matches the file's.
class AddSourceToMakerPreviews < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_previews, :source, :string, null: false, default: "renderer"
  end
end
