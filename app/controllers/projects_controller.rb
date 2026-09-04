# Server-rendered web UI for the maker Projects hub: list, create, edit, and a detail page
# tying together a build log, attached design files, and tasks.
#
# Maker data is backend-neutral: it does not live in the file library, so the file backend being
# unreachable degrades design-file THUMBNAILS (see Maker::Previews::ThumbnailMap) but never the
# page. This controller stays on the maker side of the FileLayer port — it only READS file
# metadata (never writes/moves/deletes bytes), so none of the §10 tripwire surfaces are touched.
class ProjectsController < ApplicationController
  before_action :set_project, only: %i[show edit update destroy unarchive]

  # Exposes the `capabilities` helper the attachments panel's upload control branches on
  # (chunk two-phase vs. share/s3 multipart). Read-only here — no action is capability-gated.
  include LibraryCapabilities

  # ?move_conflict=<id> — the prompt an attach leaves behind when the auto-move into this
  # project's folder hit a name collision. The same prompt renders on the file page; an attach can
  # come from either.
  include MoveConflicts

  # "Edit in <Addon>" for an attached file an addon produced — the attachment tiles carry the same
  # right-click menu as the Files page, so they need the same attribute. Read-only, like everything
  # else this controller does with the library.
  include AddonOrigins

  # The page's ONE live-node index. `#show` renders two surfaces off the library — the attachment
  # tiles and the build-log photos — and both ask the same question of the same table.
  include PageNodes

  # One flat list of live projects, newest activity first. `?archived=1` swaps in the archived
  # ones. The web reads `status` as archived-or-not and never shows or sets the other four values
  # (spec decision #1) — the column, its validation and the v1 API are deliberately untouched.
  def index
    # `== "1"`, not `.present?`: a checkbox submits "0" for off, and `.present?` would read that as
    # "show me the archive" — the opposite page.
    @archived_view = params[:archived] == "1"
    all = current_user.maker_projects.includes(:file_attachments).order(updated_at: :desc).to_a
    archived, live = all.partition { |p| p.status == "archived" }
    @projects = @archived_view ? archived : live
    @archived_count = archived.size
    @covers = Maker::Previews::ThumbnailMap.for(current_user, @projects.filter_map(&:cover_node_id))
  end

  def show
    # A FILE DELETED FROM THE LIBRARY LEAVES THE PROJECT, IMMEDIATELY. It used to sit here forever
    # as a "⚠️ (file unavailable)" tile with a per-file Remove button: `Library::Reconciler`
    # TOMBSTONES rather than destroys (deliberately — it is what makes a NAS reorganisation
    # survivable), so no `dependent:` callback fires and nothing swept these.
    #
    # HIDING IS THE INSTANT HALF; DESTROYING IS `Maker::AttachmentReaper`'s AND IT WAITS. A
    # tombstone is one undo away from returning with the SAME node_id, and the attachment is keyed
    # on that id — so destroying inside the undo window would turn "restore from Trash" into
    # "restore, then re-file this into every project by hand". Hiding is reversible, so it is
    # instant; destroying is not, so it waits out the grace window.
    #
    # `.present` is what makes the nil mean something: nil here is "this user has no LIVE node with
    # that id", i.e. tombstoned or hard-gone, which is exactly the set that should not render.
    # ONE index and ONE ThumbnailMap over the page's whole union (PageNodes) — the attachment tiles
    # and the build-log photos ask the same two questions of the same rows, and asking twice cost a
    # duplicated `nodes` query, a second `stat_all` and a second `maker_previews` read — FOUR fewer
    # STATEMENTS per render, measured on chunk (19 → 15 on one attachment plus one build-log photo).
    # Three THINGS, four STATEMENTS: chunk's `stat_all` is two statements, not one (`nodes` +
    # `versions` — §14a pins the count as constant-in-N rather than a literal, and records that
    # chunk needs 2 where share/s3 need 1). An earlier version of this comment said THREE by
    # counting the things and calling them statements; a reviewer re-measured. The absolute numbers
    # are fixture-dependent and the DELTA is the portable claim, so trust the delta.
    # A CONSTANT-FACTOR saving, not a complexity change, which is why page_query_budget_test.rb's
    # constancy-in-N assertion stays green either way and is NOT the guard for this: the guard is
    # page_nodes_test.rb, and the reason for the merge is the liveness hole, not the queries.
    # It also halves the enqueue budget the page can spend:
    # ThumbnailMap::BACKFILL_LIMIT is PER CALL, so this is 100 for the page rather than 100 + 100.
    # Self-healing across renders, and the honest trade for the union being deduped.
    all_attachments = @project.file_attachments.order(:position).to_a
    # :rich_text_body is Action Text's association for `has_rich_text :body`. Without it, each
    # entry's body is its own query — 15 entries cost 15 extra round-trips. Pinned by
    # test/integration/web/page_query_budget_test.rb. Loaded HERE, above the index, because its
    # photos are half of the union below.
    @entries = @project.build_log_entries
                       .includes(:file_attachments, :rich_text_body)
                       .reorder(logged_at: :desc).to_a
    entry_photo_ids = @entries.flat_map { |e| e.file_attachments.map(&:node_id) }
    @page_nodes = live_nodes_for(all_attachments.map(&:node_id) + entry_photo_ids)
    @attachments, missing = all_attachments.partition { |a| @page_nodes.key?(a.node_id) }
    # NOT SILENT. The panel says how many left and points at the Trash, because a user who deleted
    # a file by accident and watched their project change otherwise has no thread to pull. It
    # disappears on its own when the reaper clears the rows.
    @missing_attachment_count = missing.size

    # The folder project-view uploads go into. Best-effort (re-ensured here so a folder the user
    # deleted is recreated); nil → uploads fall back to the library root rather than 500 the page.
    # AND IT RUNS BEFORE THE LISTING BELOW, which reads the folder_node_id this (re)writes —
    # looking at a folder must never be what mints it (docs/invariants/project-intake.md).
    @upload_parent_node_id = begin
      @project.ensure_library_folder!(current_user).node_id
    rescue StandardError
      nil
    end

    # THE FOLDER IS WHAT THE PANEL SHOWS; @attachments stay the file→project RELATION (detach,
    # cover, addon origin, the missing count). Maker::ProjectFolderListing reads folder_node_id and
    # never mints a folder — the ensure above is the one writer, and it runs first. An attachment
    # whose node is not among the listing's own (capped) ids is Linked: attached to this project but
    # living somewhere else in the library, so it gets its own group with Detach and a move-in
    # button instead of the plain folder tile.
    @listing = Maker::ProjectFolderListing.new(current_user, @project)
    # "Linked" is a FOLDER question, asked of the tree, not a LIST question: the listing is capped
    # at FILE_CAP and never enters a repository, so an attached file past the cap or inside a repo
    # is absent from `node_ids` while sitting squarely in the folder — it must not reappear as
    # "linked from elsewhere".
    @linked_rows = @attachments.reject { |a| @listing.contains?(@page_nodes[a.node_id]) }
                               .map { |a| Maker::ProjectFolderListing::Row.new(node: @page_nodes[a.node_id], attachment: a, linked: true) }
    # Dead ids never reach either list: @listing only ever holds live nodes, and @attachments has
    # already dropped anything @page_nodes could not find — `stat_all` would answer nothing for a
    # gone id anyway, but it would still spend a slot in the ORDERED walk BACKFILL_LIMIT bounds.
    tile_ids = @listing.node_ids + @linked_rows.map(&:node_id)
    @page_thumbs = Maker::Previews::ThumbnailMap.for(
      current_user, tile_ids + entry_photo_ids.select { |id| @page_nodes.key?(id) }
    )
    # TILE_IDS ONLY, NOT THE BUILD-LOG PHOTOS. `_attachment_group` is the only partial on this page
    # whose tiles carry `contextmenu->filemenu#open` (`_repo_group`'s tiles are directories and
    # carry no file menu at all); `_log_entry`'s photos are spans driven by the `thumbs` controller
    # alone, with no menu to add an entry to — so an origin resolved for one would be work nothing
    # reads. That is why entry photos are not merged into this union either.
    @addon_origins = addon_origins_for(tile_ids)
    @tasks = @project.tasks.order(:position, :created_at).to_a
    @sheets = @project.sheets.to_a
    # The entry form binds to a real object: `rich_text_area` reads its value from the form's
    # object, and Action Text's form helper is not built for the object-less `fields_for` the plain
    # textarea used.
    @new_entry = @project.build_log_entries.new
    @move_conflict = move_conflict_prompt
    # `== "1"`, not `.present?` — the same reading #index applies to `archived`. Set by
    # Projects::ScansController's async branch; it is a one-shot render hint, not state, which is
    # why it rides in the url rather than in the session: the reload navigates to the param-free
    # url and the hint is gone by construction.
    @scan_started = params[:scanning] == "1"
  end

  def new
    @project = current_user.maker_projects.new(status: "planning")
  end

  def create
    @project = current_user.maker_projects.new(project_params)
    if @project.save
      ensure_project_folder(@project)
      redirect_to project_path(@project), notice: "Project created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @project.update(project_params)
      redirect_to project_path(@project), notice: "Project updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Soft archive — the model's lifecycle op (keeps the record + its history). Hard delete is a
  # deliberately deferred secondary affordance.
  def destroy
    @project.archive!
    redirect_to projects_path, notice: "Archived #{@project.name}."
  end

  # The inverse of #destroy (which archives). Redirects to the live list, where the project has
  # just reappeared — landing back on the archived view it left would read as a no-op.
  def unarchive
    @project.unarchive!
    redirect_to projects_path, notice: "Restored #{@project.name}."
  end

  private

  def set_project
    @project = current_user.maker_projects.find_by!(slug: params[:id])
  end

  # Best-effort: a project MUST save even if the library backend can't make its folder right now
  # (unmounted NAS, bucket blip). The folder is re-ensured on the next upload. Never fail creation
  # on a folder hiccup — hence the broad rescue.
  def ensure_project_folder(project)
    project.ensure_library_folder!(current_user)
  rescue StandardError => e
    Rails.logger.warn("[projects] folder ensure failed for #{project.slug}: #{e.class} #{e.message}")
  end

  # `cover_clear` is the form's way back to the automatic pick — see `_form.html.erb`. It is NOT a
  # column, so it is stripped here rather than permitted: `permit`ting it would hand `update` an
  # unknown attribute and raise.
  #
  # CLEARING WINS OVER CHOOSING when a submit somehow carries both, and the order of these two lines
  # is the whole of that rule. It is the safe way round: a stray blank clears a cover the user can
  # re-pick in two clicks, where the reverse would silently ignore a Clear they explicitly ticked.
  #
  # `cover_node_id` IS NOT VALIDATED AGAINST A LIVE NODE, deliberately. The chooser only offers the
  # user's own files, and a hand-posted id belonging to someone else is not a leak: every surface
  # that renders a cover looks it up through `current_user` (`Maker::Previews::ThumbnailMap`), so a
  # foreign id resolves to nothing and the card falls back to its placeholder. Adding a validation
  # would buy a nicer error for a case nobody reaches through the UI, at the price of a query on
  # every project save.
  def project_params
    attrs = params.require(:project).permit(:name, :description, :status, :cover_node_id)
    attrs[:cover_node_id] = nil if params[:project][:cover_clear] == "1"
    attrs
  end
end
