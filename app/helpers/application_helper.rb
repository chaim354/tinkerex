module ApplicationHelper
  # WHERE A "Back" BUTTON SHOULD ACTUALLY GO: the page the user arrived from, when we can prove it
  # is one of ours, and `default` otherwise.
  #
  # THE BUG THIS REPLACES IS THAT `link_to "Back", files_path` IS NOT A BACK BUTTON — it is a link
  # to the library root wearing the label of one. Every route into a file page loses its context:
  # six folders deep it dumps you at the top, mid-filter it clears the filter, and reached from a
  # project's Files panel it walks you out of the project entirely. That is the whole of the
  # reported complaint ("the back button just brings back to the files view no matter what").
  #
  # THE REFERER, NOT A `?return_to=` PARAM, and the choice is about how many call sites have to be
  # right. A file page is reachable from the files list, the grid, a project panel, a model's
  # bundle, the trash, an addon save redirect and any search — threading a param through all of
  # them is seven edits that must agree, plus an eighth that gets forgotten and silently reverts to
  # today's behaviour. The referer is already correct for every one of them, including the ones
  # nobody has written yet, and Turbo sets it on link navigations exactly as a full load does.
  #
  # IT IS NEVER AN OPEN REDIRECT, because the ONLY thing that survives is the path+query — the
  # scheme, host and port are compared against this request's and then DISCARDED, so what reaches
  # `href` is always a root-relative path on this origin. A cross-origin referer is not sanitised,
  # it is dropped. (`files/show.html.erb`'s existing `return_to: "file"` takes the other route to
  # the same guarantee: an allowlisted FLAG rather than a URL. Both are fine; neither ever puts an
  # attacker-supplied host in a link.)
  #
  # A REFERER EQUAL TO THE CURRENT PAGE FALLS BACK TO `default`, and that case is ordinary rather
  # than exotic: adding a note, deleting a note and resolving a move conflict all redirect to this
  # same file page, so without this guard the button would point at the page it is on and read as
  # broken. Compared on path+query so `?x=1` and `?x=2` are correctly different pages.
  def back_target_path(default:)
    referer = safe_referer_path
    return default if referer.nil?
    return default if referer == request.fullpath

    referer
  end

  # THE PRIVATE SPELLING OF "the URL of a derived asset", AND THE ONLY ONE (hardening, 2026-09-08;
  # tinkerex#278). `url_for(preview.asset)` is a signed blob URL that never expires and asks nothing
  # about who is looking — fine on a session-authed page, which is the only place this may be
  # called. A PUBLIC page's counterpart is `Maker::PublicProject#preview_url_for`, which goes
  # through the project's own permission and hands out a service URL that expires in five minutes.
  #
  # IT EXISTS SO THE SHARED PARTIALS BUILD NO URL AT ALL. `files/_thumb` and the four viewer
  # partials that render a thumbnail are rendered by BOTH pages, so each takes the URL as a strict
  # local: the maker's page passes this, a visitor's passes the public builder, and neither partial
  # can tell — the same design `named_url:` already uses (docs/invariants/files-preview.md), now
  # enforced by a third arm of the Public seam guard that refuses `url_for` in those files.
  #
  # NIL IS THE ANSWER FOR EVERY NON-READY STATE, which is what lets a caller pass it unconditionally
  # beside a `thumb&.status == "ready"` branch without a second condition to keep in step.
  def preview_src(preview)
    return nil unless preview&.status == "ready" && preview.asset.attached?

    url_for(preview.asset)
  end

  private

  # The referer as a root-relative path, or nil when there isn't a usable same-origin one.
  # URI::InvalidURIError is caught because `referer` is a client-supplied header and a malformed
  # one must degrade to "no referer", not 500 a page that merely wanted to draw a button.
  def safe_referer_path
    raw = request.referer.presence
    return nil if raw.nil?

    uri = URI.parse(raw)
    return nil unless uri.host == request.host && uri.port == request.port
    return nil unless uri.scheme == request.scheme
    return nil if uri.path.blank?

    uri.query.present? ? "#{uri.path}?#{uri.query}" : uri.path
  rescue URI::InvalidURIError
    nil
  end

  # ONE SPELLING FOR "HOW MANY OF THESE ARE THERE" (UI-cohesion spec §2.7). The app wrote counts
  # eight ways — `3 items`, `4 files`, `6 entries`, `Folders 1`, `0 shelves`, `LOOSE (4)` — in
  # different words, placements and typefaces. This owns the two decisions every toolbar count
  # shares and nothing else: the number is DELIMITED (Files did this, Inventory did not, so a
  # library of 12000 files read "12000 items" on one page and "12,000 items" on another) and the
  # noun is pluralised against the RAW count, never the delimited string — `pluralize` inspects its
  # first argument, and handing it "1,000" would make it agree with a String.
  #
  # DELIBERATELY NOT A PLACEMENT OR A WRAPPER. It returns text; where the count sits and what
  # element holds it is the toolbar's business (slice 4 settles the order). A helper that emitted
  # the `<span class="toolbar-count">` too would have to know which page it was on, since Inventory
  # pushes its count right and Files sits it against a spacer.
  # Built directly rather than by post-processing `pluralize`'s output: delimiting the number by
  # `.sub`bing the raw count out of "1000 items" corrupts any label whose own text contains those
  # digits ("3 3d models"), and the failure is silent.
  def count_label(count, singular, plural = nil)
    word = count == 1 ? singular : (plural || singular.pluralize)
    "#{number_with_delimiter(count)} #{word}"
  end
end
