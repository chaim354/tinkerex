module Public
  # GET /u/:handle — a maker's public projects (stage 3, S3-4).
  #
  # `publicly_listed`, NOT `published`: an unlisted project has a URL for whoever was handed the
  # link and must never appear on a list. The two scopes read almost identically and mean opposite
  # things here, which is why public_explore_test.rb mutation-checks exactly this substitution —
  # and why public_user_page_test.rb checks it again now that the list is paged: a scope that
  # leaked unlisted projects would also shift what lands on page 2.
  class UsersController < BaseController
    # THE PAGE IS BOUNDED, AND THE BOUND IS WHAT AN ANONYMOUS REQUEST COSTS (hardening, 2026-09-08;
    # tinkerex#279). Every card stats a node and renders a cover, so an unpaged /u/:handle let a
    # stranger ask a maker with 5,000 public projects for 5,000 covers in one GET — the port work
    # and the render both grew without limit and nothing rate-limits a public page. Same 60 as
    # Public::ExploreController::PAGE deliberately: the two lists render the same card in the same
    # grid, and a visitor who moves between them should not meet two page sizes.
    PAGE = 60

    def show
      @owner = owner!
      scope = @owner.maker_projects.publicly_listed
      # THE COUNT IS A SECOND QUERY BOUGHT ON PURPOSE: the head says "N public projects" and that N
      # is the TOTAL, not the size of this page — a maker's page stuck at "60 public projects"
      # forever would be lying about the library it exists to advertise. One COUNT is constant in
      # N (`page_query_budget_test.rb` still measures this page as constant), where the total
      # cannot be recovered from a limited relation at all. One COUNT is also all a maker's page
      # needs: it is a single-owner list, not a cross-user one, so there is no per-row count here.
      @total = scope.count
      @pages = [ (@total.to_f / PAGE).ceil, 1 ].max
      @page = requested_page
      # PAST THE LAST PAGE IS A 404, NOT AN EMPTY PAGE. `?page=900` on a maker with two pages names
      # nothing; answering 200 with an empty grid would invite a crawler to walk forever and would
      # tell a visitor their link is fine when it is not. Page 1 always exists (`@pages` floors at
      # 1), so an empty maker still renders "No public projects yet."
      raise ActiveRecord::RecordNotFound if @page > @pages

      # `:file_attachments` IS LOAD-BEARING (stage 4, S4-5): Maker::Project#cover_node_id falls back
      # to #derived_cover_node_id, which reads them, so without it the cover slot is a query per
      # card — MEASURED at 8 small / 20 large against a constant 6, by "public users#show does not
      # grow with the number of projects" in page_query_budget_test.rb.
      #
      # `:user` IS DELIBERATELY NOT HERE, AND THAT IS A MEASUREMENT RATHER THAN A PREFERENCE. The
      # card renders `project.user.handle` twice, so an eager load looks obviously right — but these
      # projects are loaded THROUGH `@owner`'s own association, whose automatic `inverse_of` has
      # already set `user` on every row, so `includes(:user)` preloads nothing and dropping it moved
      # neither number (6/6 either way, mutation-checked). An eager load that buys nothing is the
      # same thing Public::ExploreController's comment refuses. If this list is ever rebuilt from
      # `Maker::Project.where(user: @owner)` the inverse goes with it and this becomes a query per
      # card — which that budget is what would say.
      #
      # OFFSET PAGING, AND IT IS ENOUGH HERE: the list is one owner's, ordered by a column the owner
      # edits rarely, and the deep pages nobody reaches are exactly the ones where a keyset cursor
      # would pay off. `id: :desc` IS THE TIE-BREAK AND IS NOT DECORATION — two projects saved in the
      # same second (a bulk import, a tag rename that touches several rows) have equal `updated_at`,
      # and an ORDER BY that cannot separate them lets the database answer page 1 and page 2 in
      # orders that disagree, so a project appears twice and another never appears at all. NOTHING
      # IN THE SUITE CATCHES ITS REMOVAL and that was measured, not assumed: SQLite answers equal
      # keys in rowid order at both offsets, so the obvious guard passes with the tie-break gone
      # (public_user_page_test.rb records the probe). Postgres is under no such obligation.
      @projects = scope.includes(:tags, :file_attachments)
                       .order(updated_at: :desc, id: :desc)
                       .limit(PAGE).offset((@page - 1) * PAGE).to_a
      # ONE ThumbnailMap FOR THE WHOLE PAGE — and since #279 "the page" is at most PAGE projects,
      # which is the bound the issue asked for: the map stats exactly the covers this page renders,
      # never the whole library. It CAN be one map because this page has exactly one
      # owner — which is the whole reason /explore does not get covers (S4-5's Amendment 9: a
      # cross-user list is one map per maker). `.for` backfills, which is what starts the render
      # for a project nobody has opened; the public project page has done the same on an anonymous
      # visit since S3-4. READY rows only at the view: nothing here polls, because
      # /files/thumbnails is session-authed.
      #
      # ONLY THE COVERS THE PROJECT MAY SHOW (S4-5 review): `cover_node_id` is a raw column a maker
      # fills from a chooser that browses the WHOLE library, so it can name a file outside the
      # folder and unattached — which the project page's hero refuses through `permits?`. The card
      # asks the same rule, once for the page: `permitted_cover_ids` is `claimed?` batched, constant
      # in the number of projects, and a project it omits renders the placeholder.
      @cover_ids = Maker::PublicProject.permitted_cover_ids(@owner, @projects)
      @covers = Maker::Previews::ThumbnailMap.for(@owner, @cover_ids.values.uniq)
    end

    private

    # ANYTHING THAT IS NOT A POSITIVE INTEGER IS PAGE 1, never an error and never a 404: `?page=`,
    # `?page=abc` and `?page=0` are what a hand-edited URL, a truncated link and an off-by-one
    # client produce, and the honest answer to all three is the first page. `to_i` is the whole
    # parse — it answers 0 for junk, which this floors to 1. It is `params[:page]`, not the
    # session: nothing on a public page may read who is asking (§14d).
    def requested_page
      n = params[:page].to_i
      n < 1 ? 1 : n
    end
  end
end
