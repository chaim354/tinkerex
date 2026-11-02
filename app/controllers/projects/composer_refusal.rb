module Projects
  # A REFUSED COMPOSER KEEPS WHAT WAS TYPED (2026-11-02, the UX audit's B3). The README, Releases,
  # BOM and Wiring doors used to answer a refusal with a redirect and an alert, so a version that
  # was already taken, a part with no target or a README saved over a newer one came back to an
  # empty form — the typed text gone, the error in a toast above a page that no longer showed it.
  # Project details and model edit already re-rendered and kept their input; these four now do too.
  #
  # TWO ANSWERS, BOTH 422, AND THE CLIENT PICKS (Projects::TasksController's idiom):
  #   turbo_stream -> replace the composer ALONE, by its id, with the same partial rendered open, the
  #     error inside it and every field holding what was posted. Nothing else on the page is
  #     re-rendered, so a draft in another panel survives the refusal too. Turbo applies a stream
  #     whatever the status, so the 422 costs nothing and tells the truth.
  #   html -> no page to patch, so projects/composer_page renders the same partial on a page of its
  #     own under the project's crumbs. The no-JavaScript path and what a plain request test sees.
  #
  # THE COMPOSER IS RE-RENDERED, NEVER THE HUB: the hub's data is ProjectsController#show's, and a
  # second copy of that here is the drift a re-render would buy. Each composer partial takes its
  # own locals and reads no page ivar for exactly this reason.
  module ComposerRefusal
    private

    # `id` is the composer's element id (the partial sets the same one); `title` heads the page
    # the html answer renders.
    def refuse_in_composer(project, id:, partial:, locals:, title:)
      locals = locals.merge(open: true)
      respond_to do |format|
        format.html do
          @project = project
          render "projects/composer_page", locals: { partial:, locals:, title: }, status: :unprocessable_entity
        end
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(id, partial:, locals:), status: :unprocessable_entity
        end
      end
    end
  end
end
