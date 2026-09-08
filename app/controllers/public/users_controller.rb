module Public
  # GET /u/:handle — a maker's public projects (stage 3, S3-4).
  #
  # `publicly_listed`, NOT `published`: an unlisted project has a URL for whoever was handed the
  # link and must never appear on a list. The two scopes read almost identically and mean opposite
  # things here, which is why explore_test.rb mutation-checks exactly this substitution.
  class UsersController < BaseController
    def show
      @owner = owner!
      # `:user` AND `:file_attachments` ARE BOTH LOAD-BEARING (stage 4, S4-5). The card renders
      # `project.user.handle` twice, and Maker::Project#cover_node_id falls back to
      # #derived_cover_node_id, which reads the attachments — without either eager load this page
      # is a query per card, and "public users#show does not grow with the number of projects" in
      # page_query_budget_test.rb is what says so.
      @projects = @owner.maker_projects.publicly_listed.includes(:user, :tags, :file_attachments)
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
