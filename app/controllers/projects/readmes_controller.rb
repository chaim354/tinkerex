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
  # A SAVE REDIRECTS, A REFUSAL KEEPS THE DRAFT (2026-11-02, the UX audit's B3). The whole point of
  # this door (story 5.3) is to SEE the README rendered on your own page, so a save lands back on
  # that page with the card redrawn. A refusal used to redirect too, which threw the draft away —
  # including on the stale case, where the maker had just written a README over a newer one and was
  # handed neither. It now answers 422 with the editor itself, open, holding what was typed and
  # saying what went wrong (Projects::ComposerRefusal): under Turbo the editor alone is replaced, so
  # the rest of the page stays as it was.
  #
  # THE STALE REFUSAL KEEPS THE TOKEN IT WAS POSTED WITH, so a second Save is refused again rather
  # than quietly writing the draft over the version that moved it: the maker has not seen that
  # version, and the editor says how to (open it, keep the draft, reload) instead of offering to
  # discard it.
  #
  # SINCE 2026-11-05 THE SAVE EXPANDS THE README'S LIVE REGIONS (Maker::Readme::Live, `:file` mode)
  # BEFORE WRITING — the snapshot in the file is as fresh as the Save, and the only writer of it.
  class ReadmesController < ApplicationController
    include Projects::ComposerRefusal

    STALE = "This README changed since you opened it, so nothing was saved. Your draft is below; " \
            "copy what you need, then reload the page to see the current version.".freeze
    REMOVED = "This README was removed since you opened it, so nothing was saved. Your draft is " \
              "below; copy what you need, then reload the page.".freeze

    def update
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      listing = Maker::ProjectFolderListing.new(current_user, project)
      draft = params[:content].to_s
      row = listing.available? ? Maker::Readme.row_in(listing.loose) : nil
      return refuse(project, row, draft, "This project has no folder in the library yet, so the README has nowhere to go.", listing:) unless listing.available?
      # A BLANK BODY IS REFUSED RATHER THAN WRITTEN, and it is the SERVER half of the editor's
      # `disabled` textarea: without JavaScript, or with the bundle failing to load, the buffer is
      # empty and a Save would otherwise blank a README that took an hour to write. Emptying a file
      # to zero bytes is not a thing anyone asks for; deleting it is, in the Library.
      return refuse(project, row, draft, "A README needs some text. To remove it, delete the file in the Library.", listing:) if draft.strip.empty?
      return refuse(project, row, draft, "This README is too large to edit here.", listing:) if
        row && row.node.size.to_i > FilesController::EDITABLE_MAX_BYTES

      # THE SNAPSHOT IS WRITTEN HERE (2026-11-05, live regions; spec §6): every region's body is
      # regenerated from the project's current data before the bytes go down, so the file reads as the
      # table or picture the page shows at the moment of this Save, and a hand-typed directive is
      # filled and closed. The cap is checked on the EXPANDED text, because that is what lands in the
      # file; the draft handed back on a refusal is what the maker TYPED, never the expansion.
      context = Maker::Readme::Live::Context.new(user: current_user, project:, listing:)
      body = Maker::Readme::Live.expand(draft, context:, mode: :file)
      return refuse(project, row, draft, "This README is too large to edit here once its live tables are filled in.", listing:) if
        body.bytesize > FilesController::EDITABLE_MAX_BYTES

      result = Maker::TextSave.call(
        user: current_user, node: row&.node, parent_node_id: listing.folder_id,
        name: Maker::Readme::NAMES.first, body:, base_token: params[:base_token],
        # THE PENDING EDIT ONLY WHEN THE FOLDER ITSELF IS THE WORKING TREE. A repository NESTED in
        # the folder has its own README and its own commit box; this door never touches it.
        repo_root_node_id: (listing.folder_id if listing.root_repo?)
      )
      # TextSave answers :conflict for both of its refusals (stale and removed); the maker's
      # sentence says what to do with the draft they are still holding.
      return refuse(project, row, draft, result.error == Maker::TextSave::REMOVED ? REMOVED : STALE, listing:) unless result.ok

      redirect_to project_path(project), notice: "Saved the README."
    rescue FileLayer::UnsupportedOperation
      # THE CLOBBER REFUSAL (§14a): a README appeared between the render and the Save, so the
      # create found the name taken. Refused, never replaced — the maker has not seen what is there.
      refuse(project, row, draft, "A README appeared while you were writing, so nothing was saved. " \
                                  "Your draft is below; copy what you need, then reload the page to see it.", listing:)
    rescue FileLayer::FetchError
      # The adapter's message is for an operator (§14a maps FetchError to "try again"); the maker
      # is told that, in words, with the draft still in hand.
      refuse(project, row, draft, "The library could not be reached, so nothing was saved. Try again in a moment.", listing:)
    end

    private

    # The editor again, open, holding the draft and the token it was posted with. `row` is the
    # README this door resolved (nil when there is none, or no folder), so the editor names the same
    # file the panel does; `listing` feeds its Insert menu (an unavailable one renders an empty menu).
    def refuse(project, row, body, error, listing:)
      refuse_in_composer(project, id: "readme-editor", partial: "projects/readme_editor",
                         locals: { project:, row:, draft: body, base_token: params[:base_token].to_s, error:, listing: },
                         title: row ? "Edit the README" : "Write a README")
    end
  end
end
