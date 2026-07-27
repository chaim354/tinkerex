# Resolve `?move_conflict=<attachment id>` into everything shared/_move_conflict.html.erb needs.
#
# The param is minted by Projects::AttachmentsController#attach_redirect_path when an attach
# succeeded but the auto-move into the project folder hit a name collision. It rides back to
# whichever page the attach came FROM — the file page or the project page — which is why this is a
# concern and not two copies.
#
# A CONTROLLER CONCERN, NOT VIEW LOGIC, for the reason FilesController#index already gives about
# @current_project_folder_node_id: a view must not run queries — or worse, create a project folder
# — as a side effect of being rendered. The owning action opts in and hands the view one ivar.
# (`project.folder_node_id` is READ here rather than `ensure_library_folder!` CALLED, for the same
# reason: a GET of a bookmarked URL must not resurrect a folder the user just deleted.)
#
# Everything is scoped to current_user, so a guessed or foreign attachment id resolves to nil and
# the prompt simply does not render. nil is the answer for every "can't build a prompt" case
# (missing param, stale id, tombstoned file, a project whose folder was never created) — this is a
# transient UI affordance, and a 404 for a dismissed prompt would be worse than silence.
module MoveConflicts
  extend ActiveSupport::Concern

  # What the partial renders, and NOTHING ELSE — the attachment the id names is deliberately not
  # carried. #relocate takes a node_id, not an attachment id (the attach is already committed and
  # this flow only finishes the move), so a member nobody reads would invite the next reader to
  # think the prompt still owns the row.
  ConflictPrompt = Data.define(:project, :node, :suggested_name)

  private

  def move_conflict_prompt
    id = params[:move_conflict].presence
    return nil unless id && current_user

    # attachable_type IS A GUARD, not decoration next to the id. The same table holds a file's
    # attachments to Maker::Models and to build-log entries, and the partial reads `project` as a
    # Project throughout — `.name`, project_path, the project-scoped relocate route. Without the
    # filter a model attachment's id 500s the page outright (a Maker::Model has a `title`), which
    # is the CHEAP end of it: an attachable that happened to answer those would instead render a
    # prompt offering to move the file somewhere it has nothing to do with.
    #
    # It is also what makes `attachment.attachable` safe to read unscoped below: the attachment is
    # current_user's, and every writer of this table (six of them, all in app/controllers) attaches
    # to a parent it resolved from current_user.
    attachment = current_user.maker_file_attachments
                             .find_by(id: id, attachable_type: "Maker::Project")
    return nil unless attachment

    project = attachment.attachable
    node = current_user.nodes.present.find_by(node_id: attachment.node_id)
    return nil unless project && node && project.folder_node_id.present?

    # THE CONFLICT IS OVER ONCE THE FILE IS IN THE FOLDER, and the param OUTLIVES it: #relocate
    # redirects to the project page, so a browser Back lands here with the id still in the URL.
    # Re-rendering would state something now false ("so it was left where it is") and offer to move
    # the file in as "bracket (2) (2).stl". A live collision cannot coexist with the node already
    # being there — #create answers :already_there before it can reach :conflict — so this is a
    # pure staleness check, not a second opinion about whether the names clash.
    return nil if node.parent_node_id == project.folder_node_id

    ConflictPrompt.new(
      project:, node:,
      # nil when "(2)" through "(9)" are all taken — the partial then renders the explanation
      # without the button, rather than offering to move the file to a name of nothing.
      suggested_name: Maker::MoveNode.available_name(
        current_user, parent_node_id: project.folder_node_id, name: node.name
      )
    )
  end
end
