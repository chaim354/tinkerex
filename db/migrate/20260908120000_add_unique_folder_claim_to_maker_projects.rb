# ONE PROJECT PER FOLDER PER USER, ENFORCED BY THE DATABASE (tinkerex#281). Discovery and adoption
# both check the claim before creating, and both checks can pass together — a sweep listing a folder
# a click is adopting at the same instant — after which two rows point at one folder and every
# reader that says `find_by(folder_node_id:)` picks one of them by accident. Probed on the three
# live databases first (0 duplicates on chunk_remote, share and s3, 2026-09-08), so this adds the
# index with no repair step. PARTIAL: a project with no folder yet (the form path, until its first
# `ensure_library_folder!`) is NULL here, and NULLs must never collide with each other.
class AddUniqueFolderClaimToMakerProjects < ActiveRecord::Migration[8.1]
  def change
    add_index :maker_projects, [ :user_id, :folder_node_id ], unique: true,
              where: "folder_node_id IS NOT NULL",
              name: "index_maker_projects_on_user_id_and_folder_node_id"
  end
end
