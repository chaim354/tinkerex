module Public
  # GET /u/:handle/:slug/feed(.atom) — the build log and the releases of one published project as
  # an Atom feed (stage 3, S3-6).
  #
  # THE SAME DOOR AS THE PAGE, WHICH IS THE WHOLE POINT OF `public_project!`: a private project is a
  # 404 here exactly as it is there, and an unlisted one needs its `k` — so subscribing to a feed
  # can never be a way around the visibility rule the page enforces. The token then rides every URL
  # the feed emits (`link_params`), because a reader that fetched this document will re-fetch it
  # and will follow its links, and a link without the credential leads to a 404.
  #
  # `@page_url` IS BUILT HERE, NOT IN Maker::PublicProject. An Atom document wants absolute URLs and
  # this app configures `default_url_options` for the mailer only, so `_url` helpers work where
  # there is a request and raise where there is not. This is where there is one.
  class FeedsController < BaseController
    def show
      @pub = public_project!
      @page_url = public_project_url(@pub.handle, @pub.project.slug, **@pub.link_params)
      @items = @pub.feed_items(page_url: @page_url)
    end
  end
end
