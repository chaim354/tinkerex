module Public
  # GET /u/:handle — a maker's public projects (stage 3, S3-4).
  #
  # `publicly_listed`, NOT `published`: an unlisted project has a URL for whoever was handed the
  # link and must never appear on a list. The two scopes read almost identically and mean opposite
  # things here, which is why explore_test.rb mutation-checks exactly this substitution.
  class UsersController < BaseController
    def show
      @owner = owner!
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
      @projects = @owner.maker_projects.publicly_listed.includes(:tags, :file_attachments)
                        .order(updated_at: :desc).to_a
      # ONE ThumbnailMap FOR THE WHOLE PAGE, and it CAN be one because this page has exactly one
      # owner — which is the whole reason /explore does not get covers (S4-5's Amendment 9: a
      # cross-user list is one map per maker). `.for` backfills, which is what starts the render
      # for a project nobody has opened; the public project page has done the same on an anonymous
      # visit since S3-4. READY rows only at the view: nothing here polls, because
      # /files/thumbnails is session-authed.
      @covers = Maker::Previews::ThumbnailMap.for(@owner, @projects.filter_map(&:cover_node_id))
    end
  end
end
