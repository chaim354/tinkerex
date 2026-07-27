module Projects
  # Attach an EXISTING library file to a project (or detach it). "Attach" creates a reference
  # (node_id + role) AND, on a file's first project, relocates it into that project's library
  # folder — see #create for the rule and #relocate_into_project for the mechanics. A file that
  # belongs to a Maker::Model is the exception: it brings the model's whole bundle and moves
  # nothing (#attach_model_bundle).
  # Ownership is a DB fact (current_user.nodes) — deliberately NOT a FileLayer.stat check, so an
  # unmounted backend cannot block attaching a file the user demonstrably owns.
  #
  # #relocate (the ACTION — distinct from #relocate_into_project, the private mechanics both it and
  # #create drive) is the retry for the one attach outcome that needs a decision: a name collision
  # keeps the attachment and leaves the bytes put, and the prompt MoveConflicts renders offers to
  # finish the move under a free name.
  #
  # NO CAPABILITY GATE, even though it now moves bytes: Maker::MoveNode picks the door this
  # deployment has (port move on share/s3, Sync::Mutation on chunk) and every backend has one, so
  # there is nothing to 501. The §10 boundary holds the same way Maker::LibraryFolder's does —
  # this controller calls that service and never reaches into Sync:: or the port itself.
  #
  # #create answers JSON as well as HTML: the chunk inline-upload flow (uploader_controller.js)
  # uploads via /files/{begin,finalize}_upload, then POSTs the node_id here to finish the attach.
  class AttachmentsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project, only: %i[new create relocate]

    RECENT_LIMIT = 40

    # What #create needs from a bundle attach to answer both doors: the rows the project now holds
    # for that model, and whether THIS request created any of them (a re-attach must not claim
    # 201). `created` is a flag rather than the rows, because the write is a bulk insert_all and
    # there are no instantiated new records to ask.
    Bundle = Data.define(:attachments, :created)

    # GET /projects/:project_id/attachments/new?q= — the picker: search by name + recent files.
    def new
      scope = current_user.nodes.present.where(kind: "file")
      scope = scope.where("name LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%") if params[:q].present?
      @results = scope.order(updated_at: :desc).limit(RECENT_LIMIT).to_a
    end

    # POST /projects/:project_id/attachments  { node_id }
    # POST /attachments                       { project_id, node_id, return_to? }
    #
    # ATTACHING ALSO RELOCATES — the rule is the user's: a file joining its first project should
    # live in that project's folder, and a file already claimed by another project should not be
    # yanked out of it. Put here, at the action all THREE of its own attach paths reach — the file
    # page's dropdown and the project page's picker (HTML), and the project page's inline upload
    # (JSON, uploader_controller.js) — so the verb means the same thing in each. That upload posts
    # a `parent_node_id` of the project folder, so it arrives in place and #relocate_into_project
    # short-circuits on :already_there rather than moving anything.
    #
    # "ATTACHED ⇒ IN THE FOLDER" IS NOT AN INVARIANT, and must not be read as one. It now has an
    # exception INSIDE this action, which is the first place to look: a file that belongs to a
    # Maker::Model attaches that model's whole bundle and moves NOTHING (the branch below, and
    # #attach_model_bundle). Two attach paths never reach the action at all:
    # CurrentProject#attach_addon_files_to_current_project creates the row directly (a tool save
    # DEFAULTS to the project folder, but @default_parent_node_id is a default the user can
    # override in the file chooser), and the model importer posts to Models::AttachmentsController,
    # which attaches to a Maker::Model and does not move. So this action enforces the rule for the
    # PLAIN files that pass through it; nothing enforces it library-wide.
    #
    # THE ATTACH IS THE DURABLE HALF AND THE MOVE IS BEST-EFFORT. A collision or an unmounted NAS
    # must never lose the attachment: it is a reference the user asked for, and it is exactly as
    # true with the bytes in the old folder. Same trade as #enqueue_preview and
    # CurrentProject#attach_addon_files_to_current_project.
    def create
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id))
      unless node
        return respond_to do |format|
          format.html { redirect_to not_found_return_path, alert: "That file isn't in your library." }
          format.json { render json: { error: "not_found" }, status: :not_found }
        end
      end

      # A FILE THAT BELONGS TO A MODEL IS PART OF A BUNDLE, AND A BUNDLE IS INDIVISIBLE HERE.
      # An imported model is its STL plus instructions plus cover plus source archive, curated into
      # Models/<slug>/ by the importer. The relocate below would pull ONE of those out and report
      # success, gutting the model's folder — verified against a real import.
      #
      # MEMBERSHIP IS THE ATTACHMENT, NOT THE FOLDER. A file can be moved out of Models/<slug>/ and
      # still belong to the model; a stray file can be dropped INTO that folder and not belong. The
      # maker_file_attachments row is what the data model means by "belongs to", so it is what this
      # asks.
      #
      # AND IT MOVES NOTHING, WHICH IS WHY IT IS THE SAME ON ALL THREE BACKENDS. The alternative
      # reached for first — move the model's whole FOLDER into the project — is refused outright by
      # FileLayer::S3#move (s3.rb:710), because S3 has no directory and no rename: it would be a
      # non-atomic cascade over every key with no undo for a half-finished one. A rule that
      # relocates no bytes cannot diverge between deployments.
      model = model_owning(node)
      if model
        bundle = attach_model_bundle(model)
        count = bundle.attachments.size
        return respond_to do |format|
          format.html do
            redirect_to attach_redirect_path(node, nil),
                        notice: "Attached #{count} #{'file'.pluralize(count)} from #{model.title}."
          end
          # ASPIRATIONAL SHAPE-PARITY, NOT A SERVED CALLER: this branch is unreachable in
          # production. The only JSON caller (uploader_controller.js#postAttach) posts a node_id it
          # has just uploaded through the chunk two-phase flow, and a brand-new node has no model
          # attachment by construction. It answers the same keys as the single-file door below and
          # obeys the same 200-vs-201 rule (a re-attach creates nothing, so Created would be a
          # lie), so the two doors cannot drift apart while nobody is looking at this one.
          format.json do
            # Never nil: model_owning found a row for THIS node, #create resolved it from
            # nodes.present, and the bundle is that model's live files — so it is in there.
            att = bundle.attachments.find { |a| a.node_id == node.node_id }
            render json: { node_id: att.node_id, role: att.role, relocation: "model_bundle" },
                   status: bundle.created ? :created : :ok
          end
        end
      end

      # Read BEFORE the create below, or this attach is itself the "other" project.
      attached_elsewhere = current_user.maker_file_attachments
                                       .where(node_id: node.node_id, attachable_type: "Maker::Project")
                                       .where.not(attachable_id: @project.id).exists?

      # find_or_create_by, not create!: maker_file_attachments has no uniqueness index (a unique
      # one would need a backfill dedupe, and this controller is the only writer), so a
      # double-submit or a second attach from the dropdown would otherwise make a duplicate row —
      # and the file page would then render the same project chip twice.
      att = @project.file_attachments.find_or_create_by!(user: current_user, node_id: node.node_id) do |a|
        a.role = Maker::FileAttachment.role_for(node.name)
      end

      notice = "Attached #{node.name}."
      conflict = nil
      # Files only: a directory has no place in a project folder, and FileLayer::S3#move refuses
      # one outright (movable_file!) — so this would be a policy that silently works on one
      # backend and 422s on another. `relocation` stays nil when no move was attempted, which is a
      # third answer both doors report: "not moved" and "never tried" are different facts.
      relocation = nil
      if node.file? && !attached_elsewhere
        relocation = relocate_into_project(node)
        case relocation
        when :moved
          notice = "Attached #{node.name} and moved it into #{@project.name}."
        when :conflict
          # TWO CHANNELS, NEITHER REDUNDANT. `conflict` rides back as ?move_conflict=<id>, which
          # the MoveConflicts concern resolves into the rename prompt on whichever page this attach
          # came from; the notice says the same thing in words, because the flash is what a user
          # reads first and the prompt alone would let a collision look like an ordinary attach
          # until they noticed a panel further down the page.
          conflict = att.id
          notice = "Attached #{node.name} — #{@project.name} already has a file with that name, so it stayed put."
        when :unavailable
          notice = "Attached #{node.name} — couldn't move it into the project folder right now."
        end
      end

      respond_to do |format|
        format.html { redirect_to attach_redirect_path(node, conflict), notice: }
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
        format.json do
          render json: { node_id: att.node_id, role: att.role, relocation: },
                 status: att.previously_new_record? ? :created : :ok
        end
      end
    end

    # POST /projects/:project_id/attachments/relocate  { node_id, new_name? }
    #
    # The "Move it in as …" button on the collision prompt — the retry for the one #create outcome
    # that leaves something for the user to decide. `new_name` is SERVER-SUGGESTED
    # (Maker::MoveNode.available_name labels the button), but it comes back as a request param, so
    # MoveNode validates it is a leaf and #relocate_into_project maps the refusal to :unavailable:
    # a crafted name gets a flash, never a traversal and never a 500.
    #
    # NO ATTACHMENT IS CREATED OR TOUCHED HERE, which is why the action takes a node_id rather than
    # the attachment id the prompt was built from. #create already committed the attach — that is
    # the durable half — and all that is left is the move it could not do. Taking the node_id also
    # means a stale prompt (the user detached in another tab) still finishes the move it offered
    # rather than 404-ing on a row nobody needs.
    def relocate
      # kind: "file" IS A GUARD, NOT A FILTER. #create reaches MoveNode only behind `node.file?`,
      # but here BOTH ids come from the request — and Maker::MoveNode deliberately has no cycle
      # check (see its header). A crafted node_id naming a DIRECTORY would move a dir under its
      # own descendant on share and chunk (s3 alone refuses it, via movable_file!), and a cycle in
      # `nodes` makes the WITH RECURSIVE walk in Sync::Search spin unboundedly — fatal on SQLite,
      # which has no statement timeout. Same hazard V1::NodesController#move spends
      # would_create_cycle? on; a project folder only ever holds files, so refusing is cheaper
      # than detecting.
      #
      # `current_user.nodes.present` is the rest of it: another tenant's node and a tombstone both
      # resolve to nil here, so neither reaches MoveNode at all.
      node = current_user.nodes.present.find_by(node_id: params.require(:node_id), kind: "file")
      return redirect_to(project_path(@project), alert: "That file isn't in your library.") unless node

      # EVERY SYMBOL #relocate_into_project CAN ANSWER HAS A SENTENCE, including :already_there —
      # unreachable from the prompt's own button (it always sends a new_name, and a rename in place
      # is a real move) but reachable from a resubmitted or hand-made POST without one, where
      # "Couldn't move it" would be a lie about a library that is already the way the user asked.
      case relocate_into_project(node, new_name: params[:new_name].presence)
      when :moved
        redirect_to project_path(@project), notice: "Moved #{node.name} into #{@project.name}."
      when :already_there
        redirect_to project_path(@project), notice: "#{node.name} is already in #{@project.name}."
      when :conflict
        redirect_to project_path(@project), alert: "That name is taken too — left the file where it is."
      else # :unavailable — the backend is unreachable, or the name is not a leaf.
        redirect_to project_path(@project), alert: "Couldn't move #{node.name} right now."
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

    # The Maker::Model this node belongs to, or nil. SCOPED TO current_user through the attachments
    # table: maker_file_attachments keys files by a bare node_id string with no FK, so an unscoped
    # lookup would happily find another user's row pointing at the same id and attach that
    # stranger's whole bundle into this project.
    #
    # One row, not a set: a file attached to two models is storable (Models::AttachmentsController
    # can do it) and there is no sensible way to attach "both bundles" to one project without
    # surprising the user, so the oldest row wins. The single-file rule is what the second model
    # loses, not its files.
    #
    # `order(:id)` IS THE RULE, NOT DECORATION. A bare find_by is LIMIT 1 over an UNORDERED set: on
    # SQLite it happens to come back lowest-id-first, but on the managed Postgres deployment the
    # row depends on the plan, so an unrelated UPDATE to either row could silently switch which
    # model a file belongs to between two requests. A sentence saying "the first row wins" has to
    # be enforced by the query, or it is a guess about a query plan.
    def model_owning(node)
      current_user.maker_file_attachments
                  .where(node_id: node.node_id, attachable_type: "Maker::Model")
                  .order(:id).first&.attachable
    end

    # Attach every one of the model's LIVE FILES to this project. Idempotent per file, so
    # re-attaching a bundle — or attaching one whose cover the user already attached by hand —
    # adds no duplicate row.
    #
    # The role is derived PER FILE from its own name: a bundle is a PDF and a PNG and an STL, so
    # copying the triggering file's role would label the instructions "model".
    def attach_model_bundle(model)
      node_ids = model.file_attachments.pluck(:node_id)

      # LIVE FILES ONLY, and `kind` is as load-bearing as `deleted`. A member the user deleted is a
      # tombstone; a member that is a directory is not a file — and projects/_attachments.html.erb
      # renders EVERY row as a file tile linking to file_path(node_id), so either one is a broken
      # row on the project page. The single-file path above refuses directories for a different
      # reason (S3 cannot move them); this one refuses them because the project page cannot show
      # them. Two reasons, one answer — the file must not give the directory question two.
      names = current_user.nodes.present.where(node_id: node_ids, kind: "file")
                          .pluck(:node_id, :name).to_h
      # `&` keeps the MODEL's order, so the project lists the bundle the way the model does.
      #
      # IT ALSO DEDUPES, AND THAT IS THE ONLY THING THAT DOES. Two attachment rows for one node is
      # storable here too (no uniqueness index — see #create), and a duplicate member would
      # otherwise make the notice say "4 files" for a three-file model AND insert that row twice.
      # Nothing downstream saves it: Array#- (below) removes matching elements but does NOT dedupe
      # its receiver — measured, after a comment here claimed it did. So `#select` is not a
      # refactor of this line, and the duplicate-member test is what says so. The blast radius of
      # that missing index is now N rather than 1 — the price of N attaches in one request.
      members = node_ids & names.keys

      # FIVE QUERIES, CONSTANT IN N — deliberately not one SELECT + one INSERT per member. That
      # loop cost 2 queries per file (a 200-file model measured 407 queries / 113 ms) and it ran
      # inside a write transaction, so on the SQLite self-host deployment the write lock was taken
      # at the first INSERT and held to COMMIT: one bundle attach stalled every other writer in the
      # app. This is the shape stat_all and the Reconciler already had to fix, for the same reason.
      existing = @project.file_attachments.where(node_id: members).pluck(:node_id)
      rows = (members - existing).map do |node_id|
        { user_id: current_user.id, attachable_type: "Maker::Project", attachable_id: @project.id,
          node_id:, role: Maker::FileAttachment.role_for(names[node_id]) }
      end

      # insert_all SKIPS VALIDATIONS, so what they were protecting has to hold by construction, and
      # it does: role_for answers a member of ROLES for ANY input (it fetches with an "other"
      # default), node_id comes from a nodes row so it is present, and user/attachable are set
      # right here. There are no callbacks on Maker::FileAttachment to lose, `position` has a DB
      # default, and insert_all DOES stamp created_at/updated_at (record_timestamps) — both are
      # NOT NULL, so a Rails that stopped doing it would fail loudly rather than quietly.
      #
      # IT ALSO MAKES THE WRITE ONE STATEMENT, WHICH IS NOW THE WHOLE ATOMICITY STORY. A
      # half-attached bundle is worse than none — it is the gutted-folder failure again, wearing
      # the attachment table instead of the library — and a single INSERT cannot half-apply, so the
      # transaction that used to say this is gone rather than merely unnecessary. (A bundle is tens
      # of files; nothing here is sized for a bind-parameter limit.)
      Maker::FileAttachment.insert_all(rows) if rows.any?

      Bundle.new(attachments: @project.file_attachments.where(node_id: members).to_a,
                 created: rows.any?)
    end

    # Move `node` into this project's library folder. Returns a SYMBOL rather than raising,
    # because every outcome here is a normal thing that happens to a user's library and the caller
    # renders a different sentence for each — an exception would make the happy path the only one
    # written down.
    #
    # `new_name:` is unused by #create, which always moves under the node's own name; it is what
    # the collision prompt's retry passes ("move it in as bracket (2).stl") through #relocate. It
    # is a KEYWORD rather than a second positional so the `new_name.nil?` short-circuit reads as
    # what it is: renaming in place is a real move, so only a same-folder move under the SAME name
    # is a no-op — which is why :already_there is unreachable from the prompt's own button and
    # reachable only from a POST that omits the name.
    def relocate_into_project(node, new_name: nil)
      folder = @project.ensure_library_folder!(current_user)
      return :already_there if new_name.nil? && node.parent_node_id == folder.node_id

      Maker::MoveNode.call(current_user, node:, new_parent_node_id: folder.node_id, new_name:)
      :moved
    rescue Maker::MoveNode::Collision
      :conflict
    rescue FileLayer::FetchError, FileLayer::NotFound, FileLayer::UnsupportedOperation,
           Maker::MoveNode::InvalidName => e
      # EVERY CLASS HERE IS NAMED, AND THE LIST IS DELIBERATELY NARROW. This rescue wraps the whole
      # method body, so anything it catches is reported to the user as "the library is having a bad
      # day" — which makes a too-wide list a machine for turning bugs into outage messages that no
      # test can see. It caught bare ArgumentError until a review drove the consequence: arity
      # drift in a port adapter's #move, a kwarg rename in MoveNode, or a nil reaching
      # File.extname anywhere below all became a 302 and a warn line, with a green suite. So:
      #
      #   InvalidName          — the name is not a single path segment (MoveNode#leaf!). A SUBCLASS
      #                          of ArgumentError precisely so bare ArgumentError can stay a 500,
      #                          the same argument LibraryCapabilities makes for leaving
      #                          NotImplementedError un-rescued. This matters more once the rename
      #                          prompt routes a USER-TYPED name through here: someone typing
      #                          "../evil" must be told the name is bad, not that the NAS is down.
      #   FetchError           — the share is unmounted or the bucket is unreachable. Retryable.
      #   UnsupportedOperation — this backend refuses this move (S3 and directories; a destination
      #                          name taken in the store that the catalog did not know about).
      #   NotFound             — see below.
      #
      # ActiveRecord::RecordInvalid was in this list and is GONE: no producer was found on this
      # path (the move assigns a parent_node_id already checked live and a name #leaf! has already
      # vetted, and Node validates only node_id/name presence and kind inclusion), so it was a
      # guess — and an unjustified class here is exactly the bug-hiding shape above. If a real
      # producer turns up, add it back WITH its name.
      #
      # NotFound IS IN THIS LIST DELIBERATELY. Here it cannot be a caller error: #create has
      # already resolved the node from `current_user.nodes.present`, so it is live and ours, and
      # ensure_library_folder! has just proved the destination exists. What is left is a race
      # (tombstoned between those two statements) or an out-of-band change under a share/s3 store
      # — and either way the attachment row is ALREADY COMMITTED, so letting it escape would 500 a
      # request whose durable half succeeded.
      #
      # AN EARLIER DRAFT OF THIS PARAGRAPH PREDICTED that the then-unwritten #relocate action,
      # "which the user asks for explicitly", would branch on NotFound separately and answer 404.
      # It does not, and should not: #relocate resolves its node from `current_user.nodes.present`
      # with `kind: "file"` BEFORE reaching here, so every caller-error shape (unknown id, another
      # tenant's node, a tombstone, a directory) already has its own flash and never gets this far.
      # What survives that guard is the same race this paragraph describes, and the same answer.
      #
      # The node_id and slug are not decoration: :unavailable persists no marker anywhere, so this
      # line is the entire audit trail for "which files failed to move during the outage".
      Rails.logger.warn("attach relocate failed for node=#{node.node_id} project=#{@project.slug}: " \
                        "#{e.class}: #{e.message}")
      :unavailable
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
    # action is reached from. A collision rides back as ?move_conflict=<attachment id>, which the
    # MoveConflicts concern renders the rename prompt from — on either page, which is why the
    # param travels rather than the prompt living on one of them.
    def attach_redirect_path(node, conflict_id)
      if params[:return_to] == "file"
        file_path(node.node_id, move_conflict: conflict_id)
      else
        project_path(@project, move_conflict: conflict_id)
      end
    end
  end
end
