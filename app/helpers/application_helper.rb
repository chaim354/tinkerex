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
end
