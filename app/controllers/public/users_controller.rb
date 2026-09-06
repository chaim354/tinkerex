module Public
  # GET /u/:handle — a maker's public projects (stage 3, S3-4).
  #
  # `publicly_listed`, NOT `published`: an unlisted project has a URL for whoever was handed the
  # link and must never appear on a list. The two scopes read almost identically and mean opposite
  # things here, which is why explore_test.rb mutation-checks exactly this substitution.
  class UsersController < BaseController
    def show
      @owner = owner!
      @projects = @owner.maker_projects.publicly_listed.includes(:tags).order(updated_at: :desc).to_a
    end
  end
end
