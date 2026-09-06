module Public
  # GET /u/:handle/:slug — one project, read-only, for anyone (stage 3, S3-4).
  #
  # EVERY QUESTION THE PAGE ASKS GOES TO ONE OBJECT. `Maker::PublicProject` is loaded here and
  # rendered through; the view reads `@pub` and nothing else off this controller except the project
  # itself, so the page and the file route (Public::FilesController) can never disagree about what
  # is public. Deliberately NOT a controller full of ivars mirroring ProjectsController#show: that
  # page's ivars carry editing affordances (composers, selects, addon origins) a visitor has no
  # business seeing at all.
  class ProjectsController < BaseController
    def show
      @pub = public_project!
      @project = @pub.project
    end
  end
end
