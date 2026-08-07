# The project's chosen cover image. NULLABLE ON PURPOSE, and the null is meaningful rather than
# merely absent: `Maker::Project#cover_node_id` falls back to the derived pick (first image, else
# first model, else first attachment) when nothing is stored, which is exactly what every existing
# project relied on before this column and what a project with no cover chosen yet still gets. So
# this migration changes no project's appearance — it only makes the choice expressible.
#
# No FK and no index: `node_id` is a string node id, not a `nodes.id`, and nothing queries projects
# BY cover — it is read one project at a time off a row already loaded.
class AddCoverNodeIdToMakerProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :maker_projects, :cover_node_id, :string
  end
end
