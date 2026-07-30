class AddMetadataToMakerPreviews < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_previews, :metadata, :json
  end
end
