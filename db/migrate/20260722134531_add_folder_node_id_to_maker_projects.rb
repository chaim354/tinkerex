class AddFolderNodeIdToMakerProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_projects, :folder_node_id, :string
  end
end
