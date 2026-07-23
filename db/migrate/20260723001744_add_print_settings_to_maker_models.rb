class AddPrintSettingsToMakerModels < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_models, :print_settings, :json
  end
end
