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
  # NIL FOR EVERY ROW WITH NO PICTURE TO SHOW, which is what lets a caller pass it unconditionally
  # beside a `thumb&.showable?` branch without a second condition to keep in step. `showable?`, not
  # `current_build?`: an older build's picture of this same content stays up while its rebuild runs.
  def preview_src(preview)
    return nil unless preview&.showable?

    url_for(preview.asset)
  end

  # EVERY TIMESTAMP ON A PAGE, IN ONE ZONE AND ONE OF THREE SPELLINGS (UX audit D1, 2026-11-02).
  # The audit counted three clocks and six formats on one evening's pages: Rails columns printed in
  # UTC, file mtimes in the process's own zone, the History panel in the browser's, as
  # `%Y-%m-%d %H:%M`, `...:%S`, `%Y-%m-%d`, `%B %d, %Y`, `toLocaleString()` and "10 minutes ago".
  #
  #   :absolute  2026-11-01 22:09     the default: a row, a panel, an entry
  #   :date      2026-11-01           where the day is the fact (added, updated, printed, released)
  #   :relative  10 minutes ago       where recency is the fact (a repo's head, a device's last use)
  #
  # Always a `<time>`: `datetime` is ISO 8601 in the app's zone and `title` the full local time with
  # the zone's abbreviation, so a relative or date-only label still answers "exactly when?" on
  # hover. The zone is config.time_zone's (lib/tinkerex/time_zone.rb), applied HERE to whatever
  # arrives -- a TimeWithZone, a process-local ::Time from `Time.at` or Rugged -- which is what makes
  # a note and the file it is about, saved in the same minute, read the same minute. A Date has no
  # time of day: it prints its day in every style but :relative and carries no title. nil renders
  # as "" so a call site keeps its own placeholder (`time_at(x).presence || "—"`).
  #
  # These three are the whole vocabulary: no `strftime`, `to_fs(` or `time_ago_in_words` in
  # app/views (test/integration/web/time_format_test.rb), and the History panel prints the label
  # FilesController#history builds with #time_label rather than the browser's own.
  TIME_FORMATS = { absolute: "%Y-%m-%d %H:%M", date: "%Y-%m-%d" }.freeze
  TIME_TITLE = "%Y-%m-%d %H:%M:%S %Z".freeze
  TIME_STYLES = %i[absolute date relative].freeze

  def time_at(time, style: :absolute, **attrs)
    # The style is checked BEFORE the nil shortcut, so a typo at a nullable call site fails on the
    # first render rather than only once the column holds a value.
    raise ArgumentError, "time style #{style.inspect} is not one of #{TIME_STYLES.join(', ')}" unless TIME_STYLES.include?(style)
    return "" if time.nil?

    if plain_date?(time)
      return content_tag(:time, time_label(time, style:), datetime: time.iso8601, **attrs)
    end

    at = time.in_time_zone
    content_tag(:time, time_label(at, style:), datetime: at.iso8601, title: at.strftime(TIME_TITLE), **attrs)
  end

  # The label alone, as plain text, for a caller that is not a view: FilesController#history sends
  # it to history_controller.js as `at_label`.
  def time_label(time, style: :absolute)
    raise ArgumentError, "time style #{style.inspect} is not one of #{TIME_STYLES.join(', ')}" unless TIME_STYLES.include?(style)
    return "" if time.nil?
    return relative_label(time.in_time_zone) if style == :relative
    return time.strftime(TIME_FORMATS[:date]) if plain_date?(time)

    time.in_time_zone.strftime(TIME_FORMATS.fetch(style))
  end

  # A FileInfo / Node mtime is unix NANOSECONDS (reading it as seconds is the overflow bug this
  # codebase has shipped twice). The instant only: #time_at puts it in the app's zone.
  def time_from_nanos(nanos)
    nanos && Time.at(nanos / 1_000_000_000)
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
    # A path that begins with "//" is a protocol-relative URL to a browser: `redirect_to` would raise
    # OpenRedirectError on it (a 500 after the action already ran) and an href would leave the site.
    return nil if uri.path.start_with?("//")

    uri.query.present? ? "#{uri.path}?#{uri.query}" : uri.path
  rescue URI::InvalidURIError
    nil
  end

  def plain_date?(time) = time.is_a?(Date) && !time.is_a?(DateTime)

  # "in 3 minutes" for a time ahead of the clock, which a commit by an author whose clock runs fast
  # can be; "3 minutes ago" for everything else.
  def relative_label(at)
    words = distance_of_time_in_words(at, Time.current)
    at.future? ? "in #{words}" : "#{words} ago"
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
