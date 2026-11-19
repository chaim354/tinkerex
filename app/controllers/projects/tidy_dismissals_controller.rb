module Projects
  # POST /projects/:project_id/tidy_dismissals — the tidy-up list's Dismiss (the Shop manual's §9,
  # 2026-11-19). Session-authed web layer (§14d).
  #
  # THE BROWSER NAMES THE SUGGESTION; THE SERVER SUPPLIES ITS STATE. The form posts `kind` and
  # `subject` only. This door builds a fresh Maker::TidyUp for the project — the same listing and the
  # same checks the page drew from — and records the state THAT computed, so a dismissal can only
  # ever name a suggestion the page really raises, and only in the state it really has. A suggestion
  # that is no longer raised (the file was renamed, the source exported again) is not an error: the
  # maker's intent is already true, and the answer says so.
  #
  # NO PORT WRITE, NO GIT WRITE. The checks read; this writes one `maker_tidy_dismissals` row.
  class TidyDismissalsController < ApplicationController
    def create
      project = current_user.maker_projects.find_by!(slug: params[:project_id])
      kind = params[:kind].to_s
      subject = params[:subject].to_s
      back = project_path(project, anchor: "tidy-up")
      return redirect_to(back, alert: "That is not a suggestion this page makes.") unless Maker::TidyUp::KINDS.include?(kind)

      suggestion = tidy_for(project).find(kind, subject)
      return redirect_to(back, notice: "Dismissed nothing: that suggestion no longer applies.") if suggestion.nil?

      Maker::TidyDismissal.record!(user: current_user, project:, kind:, subject:, state: suggestion.state)
      redirect_to back, notice: "Dismissed the suggestion."
    end

    private

    # THE SAME INPUTS ProjectsController#show HANDS THE CHECKS: the project's listing (which never
    # mints a folder) and, where the library is a local folder, its repositories — the folder itself
    # when it is one, and every working tree inside it — as Nodes from ONE batched lookup.
    def tidy_for(project)
      listing = Maker::ProjectFolderListing.new(current_user, project)
      Maker::TidyUp.for(user: current_user, project:, listing:, repos: Maker::TidyUp.repos_in(current_user, listing, project))
    end
  end
end
