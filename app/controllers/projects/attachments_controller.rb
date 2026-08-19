module Projects
  # Attach an EXISTING library file to a project (or detach it), and finish an attach whose
  # auto-move hit a name collision.
  #
  # THE POLICY IS NOT HERE — it is Maker::AttachToProject, and that is the point. What "attach"
  # means (create a reference AND, on a file's first project, relocate it into that project's
  # folder; a model's file brings the whole bundle and moves nothing) is a decision with TWO doors
  # now, and while the rules lived inline in #create the second door was written below all of them:
  # #relocate pulled one file out of a model's bundle folder and reported success. Both actions
  # call the same object, so a rule cannot be missed by a door again without someone writing down
  # that they are opting out.
  #
  # Ownership is a DB fact (current_user.nodes) — deliberately NOT a FileLayer.stat check, so an
  # unmounted backend cannot block attaching a file the user demonstrably owns.
  #
  # NO CAPABILITY GATE, even though it moves bytes: Maker::MoveNode picks the door this deployment
  # has (port move on share/s3, Sync::Mutation on chunk) and every backend has one, so there is
  # nothing to 501. The §10 boundary holds the same way Maker::LibraryFolder's does — this
  # controller calls maker services and never reaches into Sync:: or the port itself.
  #
  # #create answers JSON as well as HTML: the chunk inline-upload flow (uploader_controller.js)
  # uploads via /files/{begin,finalize}_upload, then POSTs the node_id here to finish the attach.
  class AttachmentsController < ApplicationController
    before_action :set_project, only: %i[new create relocate]

    RECENT_LIMIT = 40

    # GET /projects/:project_id/attachments/new?q= — the picker: search by name + recent files.
    def new
      scope = current_user.nodes.present.where(kind: "file")
      scope = scope.where("name LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%") if params[:q].present?
      @results = scope.order(updated_at: :desc).limit(RECENT_LIMIT).to_a
    end

    # POST /projects/:project_id/attachments  { node_id }
    # POST /attachments                       { project_id, node_id, return_to? }
    #
    # Three of its own attach paths reach this action — the file page's dropdown and the project
    # page's picker (HTML), and the project page's inline upload (JSON, uploader_controller.js) —
    # so the verb means the same thing in each. That upload posts a `parent_node_id` of the project
    # folder, so it arrives in place and the relocate short-circuits on :already_there.
    #
    # "ATTACHED ⇒ IN THE FOLDER" IS NOT AN INVARIANT, and must not be read as one. Two attach paths
    # never reach this action at all: CurrentProject#attach_addon_files_to_current_project creates
    # the row directly (a tool save DEFAULTS to the project folder, but @default_parent_node_id is
    # a default the user can override in the file chooser), and the model importer posts to
    # Models::AttachmentsController, which attaches to a Maker::Model and does not move. So this
    # action enforces the rule for the files that pass through it; nothing enforces it
    # library-wide. Maker::AttachToProject#refusal_for holds the exceptions INSIDE it.
    def create
      node = current_user.nodes.present.find_by(node_id: node_id_param)
      unless node
        return respond_to do |format|
          format.html { redirect_to not_found_return_path, alert: "That file isn't in your library." }
          format.json { render json: { error: "not_found" }, status: :not_found }
        end
      end

      result = attach_to_project.call(node)

      respond_to do |format|
        format.html { redirect_to attach_redirect_path(node, conflict_id(result)), notice: attach_notice(node, result) }
        # 200, not 201, when find_or_create_by found: the whole point of the dedupe is that the
        # second attach creates nothing, so claiming Created would be a lie.
        #
        # `relocation` is here so the JSON door tells the SAME truth as the HTML one: the status
        # code cannot carry it, because the attach really did succeed and that is what the code is
        # about.
        #
        # NO CALLER READS EITHER OF THEM TODAY, and an earlier version of this comment claimed
        # otherwise ("the only caller that reads the status", "without it uploader_controller.js
        # reports 'Done.' for a file that never moved"). Both were false: the one JSON caller is
        # uploader_controller.js#postAttach, which checks `res.ok` and nothing else — it reports
        # "Done." either way, so `relocation` did not fix that and the 200/201 split is read by
        # nobody. They are kept because the honest answer is cheap and a caller that wants to say
        # "attached, but it stayed where it was" then needs no redesign; not because anything
        # downstream breaks without them.
        format.json { render json: attach_json(node, result), status: result.created ? :created : :ok }
      end
    end

    # POST /projects/:project_id/attachments/relocate  { node_id, new_name? }
    #
    # The "Move it in as …" button on the collision prompt — the retry for the one #create outcome
    # that leaves something for the user to decide. `new_name` is SERVER-SUGGESTED
    # (Maker::MoveNode.available_name labels the button), but it comes back as a request param, so
    # MoveNode validates its shape, its length and its type, and the service maps every refusal to
    # a symbol: a crafted name gets a flash, never a traversal and never a 500.
    #
    # IT TAKES A node_id, NOT THE ATTACHMENT ID the prompt was built from — the attach is already
    # committed and all that is left is the move — but the service still REQUIRES the attachment to
    # exist (:not_attached). An earlier draft of this comment argued the opposite, that a stale
    # prompt should "still finish the move it offered rather than 404 on a row nobody needs". That
    # was wrong twice over: without an attachment the file has not joined the project, so there is
    # no rule saying it belongs in that folder, and the endpoint created Projects/<slug> as a side
    # effect of being POSTed to.
    def relocate
      # kind: "file" IS A GUARD, NOT A FILTER. #create reaches the move behind the service's own
      # `node.file?` rule, but here BOTH ids come from the request — and Maker::MoveNode
      # deliberately has no cycle check (see its header). A crafted node_id naming a DIRECTORY would
      # move a dir under its own descendant on share and chunk (s3 alone refuses it, via
      # movable_file!), and a cycle in `nodes` makes the WITH RECURSIVE walk in Sync::Search spin
      # unboundedly — fatal on SQLite, which has no statement timeout. Same hazard
      # V1::NodesController#move spends would_create_cycle? on; a project folder only ever holds
      # files, so refusing is cheaper than detecting. (The service answers :not_a_file for the same
      # input; this stops it a query earlier and with the plainer sentence.)
      #
      # `current_user.nodes.present` is the rest of it: another tenant's node and a tombstone both
      # resolve to nil here, so neither reaches the service at all.
      node = current_user.nodes.present.find_by(node_id: node_id_param, kind: "file")
      return redirect_back_or_to(project_path(@project), alert: "That file isn't in your library.") unless node

      # EVERY SYMBOL Maker::AttachToProject#relocate CAN ANSWER HAS A SENTENCE. The `else` raises
      # rather than guessing: a symbol nobody worded is a programming error, and the loud version
      # is the one that gets fixed (the same argument LibraryCapabilities makes for leaving
      # NotImplementedError un-rescued).
      service = attach_to_project
      case service.relocate(node, new_name: params[:new_name].presence)
      when :moved              then relocated notice: "Moved #{node.name} into #{@project.name}."
      when :already_there      then relocated notice: "#{node.name} is already in #{@project.name}."
      when :conflict           then relocated alert: "That name is taken too — left the file where it is."
      when :bad_name           then relocated alert: "That name isn't allowed — left the file where it is."
      when :unavailable        then relocated alert: "Couldn't move #{node.name} right now."
      when :not_attached       then relocated alert: "#{node.name} isn't attached to #{@project.name}."
      when :not_a_file         then relocated alert: "Only files can be moved into a project folder."
      when :model_bundle       then relocated alert: model_bundle_alert(node, service)
      when :attached_elsewhere then relocated alert: "#{node.name} belongs to another project, so it stays in that project's folder."
      else raise ArgumentError, "unhandled relocate outcome for node=#{node.node_id}"
      end
    end

    # DELETE /attachments/:id (shallow) — remove the reference only; the library file is untouched.
    def destroy
      att = current_user.maker_file_attachments.find(params[:id])
      project = att.attachable
      att.destroy!
      redirect_back_or_to project_path(project), notice: "Detached."
    end

    private

    def set_project
      @project = current_user.maker_projects.find_by!(slug: params[:project_id])
    end

    def attach_to_project
      Maker::AttachToProject.new(user: current_user, project: @project)
    end

    # `node_id` MUST BE A BARE STRING. It arrives from the request, so `node_id[a]=b` makes it an
    # ActionController::Parameters and `find_by(node_id: <Parameters>)` raises an uncaught
    # `TypeError: can't cast` — a 500 on a garbage param. `node_id[]=x` is subtler: it becomes an
    # unordered `IN (…) LIMIT 1`, which is the same "the query has to enforce the rule" argument
    # Maker::AttachToProject#model_owning makes about order(:id). `to_s` collapses both into a
    # string that matches no node, so the answer is the honest "isn't in your library" both actions
    # already have.
    def node_id_param
      params.require(:node_id).to_s
    end

    # Land back where the button was pressed. `redirect_back_or_to` is the house pattern in this
    # controller (#destroy uses it) and needs no `return_to` plumbing: Rails refuses a cross-host
    # referer by default, so it cannot become an open redirect. Returning to the page the prompt
    # was on is safe now that the prompt stops rendering once the move it offered has happened.
    def relocated(**flash_args)
      redirect_back_or_to project_path(@project), **flash_args
    end

    # Asks the SERVICE for the model rather than re-running its query here: that duplication is
    # what this whole refactor removed. `&.` because the row can vanish between the refusal and
    # this sentence, and a flash must not 500.
    def model_bundle_alert(node, service)
      model = service.model_owning(node)
      "#{node.name} is part of #{model&.title || 'a model'} — a model's files stay together in " \
        "the model's own folder."
    end

    # THE SERVICE DECIDES, THE CONTROLLER WORDS IT. Kept apart so a change of copy cannot change a
    # rule, and so the policy is unit-testable without a request.
    def attach_notice(node, result)
      if result.model
        count = result.attachments.size
        return "Attached #{count} #{'file'.pluralize(count)} from #{result.model.title}."
      end

      case result.relocation
      when :moved
        "Attached #{node.name} and moved it into #{@project.name}."
      when :conflict
        # TWO CHANNELS, NEITHER REDUNDANT. The attachment id also rides back as ?move_conflict=<id>,
        # which the MoveConflicts concern resolves into the rename prompt on whichever page this
        # attach came from; this sentence says the same thing in words, because the flash is what a
        # user reads first and the prompt alone would let a collision look like an ordinary attach
        # until they noticed a panel further down the page.
        "Attached #{node.name} — #{@project.name} already has a file with that name, so it stayed put."
      when :unavailable, :bad_name
        # One sentence for both, unlike #relocate: here the name is the node's OWN, so a user has
        # nothing to correct and the distinction would only puzzle them.
        "Attached #{node.name} — couldn't move it into the project folder right now."
      else
        # nil (never tried — a directory, or a file another project claims) and :already_there.
        "Attached #{node.name}."
      end
    end

    def attach_json(node, result)
      # Never nil: the single-file path holds this node's own row, and on the bundle path the
      # triggering node is a live member by construction (the service resolved the bundle from a
      # model attachment for THIS node).
      att = result.attachments.find { |a| a.node_id == node.node_id }
      { node_id: att.node_id, role: att.role, relocation: result.relocation }
    end

    def conflict_id(result)
      result.attachments.first.id if result.relocation == :conflict
    end

    # Where to send a user whose node is gone. NOT file_path: the node just failed to resolve, so
    # FilesController#show (find_by! on nodes.present) would 404 on exactly the condition that got
    # us here, and take the alert down with it. The library browser is the nearest page that
    # renders — and it is a great deal closer to where the user was than another project's picker.
    def not_found_return_path
      params[:return_to] == "file" ? files_path : new_project_attachment_path(@project)
    end

    # Where to land after an attach. `return_to` is an ALLOWLISTED FLAG, not a URL — a
    # caller-supplied redirect target is an open redirect, and there are exactly two places this
    # action is reached from. (#relocate needs none of this: it is only ever reached from a form on
    # a page we rendered, so its Referer is enough.) A collision rides back as
    # ?move_conflict=<attachment id>, which the MoveConflicts concern renders the rename prompt
    # from — on either page, which is why the param travels rather than the prompt living on one.
    def attach_redirect_path(node, conflict_id)
      if params[:return_to] == "file"
        file_path(node.node_id, move_conflict: conflict_id)
      else
        project_path(@project, move_conflict: conflict_id)
      end
    end
  end
end
