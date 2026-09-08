module Projects
  # PATCH /projects/:project_id/readme — the project folder's own README, written from the project
  # page (stage 4, S4-4; spec §2 D3, story 5.3). Session-authed web layer (§14d).
  #
  # THE ONE EXCEPTION TO "NO REPOSITORY, NO EDITING", AND IT IS CONFINED BY SHAPE RATHER THAN BY A
  # CHECK: this action takes no node id, no name and no parent — it asks the project's own listing
  # which row is the README (Maker::Readme.row_in owns that preference order) and writes that, or
  # creates NAMES.first when there is none. There is no parameter that could point it at another
  # file, which is why docs/invariants/git-editing.md can describe the exception as one door rather
  # than as a predicate someone can loosen.
  #
  # ALWAYS A REDIRECT, NEVER A RE-RENDER OR JSON — Settings::HandlesController's argument, and one
  # more: the whole point of this door (story 5.3) is to SEE the README rendered on your own page,
  # so landing back on that page with the card redrawn is the feature, not a consolation.
  class ReadmesController < ApplicationController
    def update
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      listing = Maker::ProjectFolderListing.new(current_user, project)
      body = params[:content].to_s
      return refuse(project, "This project has no folder in the library yet.") unless listing.available?
      # A BLANK BODY IS REFUSED RATHER THAN WRITTEN, and it is the SERVER half of the editor's
      # `disabled` textarea: without JavaScript, or with the bundle failing to load, the buffer is
      # empty and a Save would otherwise blank a README that took an hour to write. Emptying a file
      # to zero bytes is not a thing anyone asks for; deleting it is, on the Files page.
      return refuse(project, "A README needs some text. To remove it, delete the file from the Files page.") if body.strip.empty?
      return refuse(project, "This README is too large to edit here.") if
        body.bytesize > FilesController::EDITABLE_MAX_BYTES

      row = Maker::Readme.row_in(listing.loose)
      return refuse(project, "This README is too large to edit here.") if
        row && row.node.size.to_i > FilesController::EDITABLE_MAX_BYTES

      result = Maker::TextSave.call(
        user: current_user, node: row&.node, parent_node_id: listing.folder_id,
        name: Maker::Readme::NAMES.first, body:, base_token: params[:base_token],
        # THE PENDING EDIT ONLY WHEN THE FOLDER ITSELF IS THE WORKING TREE. A repository NESTED in
        # the folder has its own README and its own commit box; this door never touches it.
        repo_root_node_id: (listing.folder_id if listing.root_repo?)
      )
      return refuse(project, result.error) unless result.ok

      redirect_to project_path(project), notice: "README saved."
    rescue FileLayer::UnsupportedOperation
      # THE CLOBBER REFUSAL (§14a): a README appeared between the render and the Save, so the
      # create found the name taken. Refused, never replaced — the maker has not seen what is there.
      refuse(project, "A README appeared while you were writing. Reload the page to see it.")
    rescue FileLayer::FetchError => e
      refuse(project, e.message)
    end

    private

    def refuse(project, message)
      redirect_to project_path(project), alert: message
    end
  end
end
