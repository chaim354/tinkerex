# Resolve `?move_conflict=<attachment id>` into everything projects/_move_conflict.html.erb needs.
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
# (missing param, stale id, tombstoned file, a project whose folder was never created, a conflict
# already resolved) — this is a transient UI affordance, and a 404 for a dismissed prompt would be
# worse than silence.
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
    # current_user's, and every writer of this table attaches to a parent it resolved from
    # current_user. Re-audited against the code (an earlier version of this list named
    # Projects::AttachmentsController, which has not written a row since the attach policy was
    # extracted, and omitted the service that took those writes over):
    #
    #   Maker::AttachToProject                — BOTH of its writes. #call's create_or_find_by! goes
    #     through @project.file_attachments, and #attach_bundle's insert_all is the only BULK write
    #     of this table anywhere: it sets user_id and attachable_type/attachable_id as COLUMNS
    #     rather than through the association, which is the one place the scoping is spelled by
    #     hand and so the one worth naming here. Both are safe by the same fact — @project comes
    #     from Projects::AttachmentsController#set_project (current_user.maker_projects).
    #   Projects::UploadsController           — #attach_target (current_user.maker_projects /
    #                                           .maker_build_log_entries).
    #   Models::AttachmentsController         — #set_model (current_user.maker_models).
    #   Projects::EntryPhotosController       — current_user.maker_build_log_entries.find.
    #   CurrentProject                        — #attach_addon_files_to_current_project, whose
    #                                           #current_project is current_user-scoped.
    #   V1::Maker::FileAttachmentsController  — #resolve_parent (current_user.public_send(...)).
    #
    # Projects::AttachmentsController only READS the table now (#destroy finds by id through
    # current_user). The safety claim above held throughout; the enumeration a future auditor
    # would have re-walked did not.
    attachment = current_user.maker_file_attachments
                             .find_by(id: id, attachable_type: "Maker::Project")
    return nil unless attachment

    project = attachment.attachable
    node = current_user.nodes.present.find_by(node_id: attachment.node_id)
    return nil unless project && node && project.folder_node_id.present?

    # ASK THE QUESTION THE PROMPT'S OWN SENTENCE ANSWERS: "a file with that name is already in the
    # project's folder". The param OUTLIVES the collision — #relocate lands back on the page the
    # button was on, browsers have a Back key, and an attachment id is a sequential integer next to
    # a URL that is on screen after any collision — so the prompt has to re-establish its premise
    # rather than assume it.
    #
    # AN EARLIER VERSION ASKED `node.parent_node_id == project.folder_node_id` — "did the move
    # happen?" — which is a DIFFERENT question, and it rendered a prompt (offering "bracket
    # (2).stl") for a project folder that was empty, for a colliding sibling deleted out of band,
    # and for a project folder that had itself been tombstoned. This subsumes it: a node already in
    # the folder cannot collide with itself, which is exactly what `except_node_id` says. It also
    # fixes the suggestion — available_name is now only ever asked about a name that IS taken.
    return nil unless Maker::MoveNode.collision?(current_user, parent_node_id: project.folder_node_id,
                                                 name: node.name, except_node_id: node.node_id)

    # AND DON'T OFFER A BUTTON THE SERVICE WILL REFUSE. A model's file, a file another project
    # claims, and a directory all keep their bytes where they are by policy — the prompt for one
    # would be a dialog whose every word is false, wired to a move that (now) answers a refusal.
    # The app never mints ?move_conflict= for any of them; typing the id does.
    return nil if Maker::AttachToProject.new(user: current_user, project:).refusal_for(node)

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
