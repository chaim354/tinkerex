require "test_helper"
require "support/public_fixture"

module Web
  # STAGE 3, S3-6: /u/:handle/:slug/feed.atom — one published project's build log and releases as
  # a feed.
  #
  # THE DOCUMENT IS PARSED AS XML, NEVER GREPPED. An Atom feed that "contains the words" is not a
  # feed; a reader parses it, and a document that is well-formed-but-wrong (no `updated`, a relative
  # link, a `content` with no type) fails in the reader and nowhere else. Every assertion below goes
  # through Nokogiri and the Atom namespace for that reason.
  #
  # THE SHARE PIN IS test/support/public_fixture.rb's, for its reasons: these suites seed nodes with
  # `create_node!`, which has bytes behind it only on share, and pinning keeps the run counts equal
  # across the three legs (§15). Nothing in THIS file reads bytes — but the fixture builds a
  # library, and a fixture that only half-works on two legs is worse than one that is pinned.
  class PublicFeedTest < ActionDispatch::IntegrationTest
    include PublicFixture

    CAP = Maker::PublicProject::FEED_CAP

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
      @f = seed_public_project!(@user)
      @project = @f[:project]
      # The fixture's own entry is at 2026-05-01; everything this suite adds is dated around it so
      # "newest first" is a real ordering rather than a tie broken by insertion order.
      @entry = @f[:entry]
    end

    teardown { FileLayer.reset! }

    def path(**opts) = public_feed_path("ada", @project.slug, **opts)

    def feed = Nokogiri::XML(response.body)

    def entry_titles(doc) = doc.xpath("//xmlns:entry/xmlns:title").map(&:text)

    def add_entry!(body, at)
      @project.build_log_entries.create!(user: @user, body:, logged_at: at)
    end

    def add_release!(version, at, notes: nil)
      @project.releases.create!(user: @user, version:, published_at: at, notes:)
    end

    # --- 1. the document ----------------------------------------------------------

    test "the feed is Atom, names the project, and carries one entry per build-log entry and release" do
      add_release!("v1.0", Time.zone.local(2026, 6, 1, 9, 0, 0))

      get path

      assert_response :success
      assert_equal "application/atom+xml", response.media_type

      doc = feed
      assert_equal "feed", doc.root.name
      assert_equal "http://www.w3.org/2005/Atom", doc.root.namespace.href
      assert_equal "Desk Lamp — @ada", doc.at_xpath("/xmlns:feed/xmlns:title").text
      assert_equal 2, doc.xpath("//xmlns:entry").size,
                   "one build-log entry and one release, and nothing else"
      assert_equal [ "Release v1.0", "Build log — 2026-05-01" ], entry_titles(doc)

      # EVERY ENTRY CARRIES ALL FOUR OF THE THINGS AtomFeedBuilder WOULD HAVE DEFAULTED FROM AN
      # ActiveRecord. These items are a Data, so a builder that stopped passing them explicitly
      # would emit a feed with no timestamps and a wrong id — well-formed, and useless to a reader.
      doc.xpath("//xmlns:entry").each do |e|
        assert_match(/\Atag:tinkerex,\d{4}-\d\d-\d\d:(entry|release)\/\d+\z/, e.at_xpath("xmlns:id").text)
        assert e.at_xpath("xmlns:updated"), "an entry with no `updated` never re-sorts in a reader"
        assert e.at_xpath("xmlns:published")
        assert_equal "@ada", e.at_xpath("xmlns:author/xmlns:name").text
      end
    end

    test "the feed's own id and links are the project's, absolute, and self-describing" do
      get path

      doc = feed
      page = public_project_url("ada", @project.slug)
      assert_equal "tag:tinkerex,#{@project.created_at.to_date}:project/#{@project.id}",
                   doc.at_xpath("/xmlns:feed/xmlns:id").text
      assert_equal page, doc.at_xpath("/xmlns:feed/xmlns:link[@rel='alternate']")["href"]
      assert_equal public_feed_url("ada", @project.slug),
                   doc.at_xpath("/xmlns:feed/xmlns:link[@rel='self']")["href"]
      assert_equal "#{page}#entry-#{@entry.id}",
                   doc.at_xpath("//xmlns:entry/xmlns:link")["href"],
                   "an item's link is the page plus its own anchor, absolute"
    end

    # --- 2. newest first, and the merge ---------------------------------------------

    # THE TWO KINDS ARE INTERLEAVED, NOT CONCATENATED, which is the only shape that can fail if
    # `feed_items` sorts each list on its own and appends. The middle item is a RELEASE sitting
    # between two build-log entries by time.
    test "entries and releases are merged newest first" do
      add_entry!("Older.", Time.zone.local(2026, 4, 1, 9, 0, 0))
      add_release!("v0.9", Time.zone.local(2026, 5, 15, 9, 0, 0))
      add_entry!("Newest.", Time.zone.local(2026, 7, 1, 9, 0, 0))

      get path

      assert_equal [ "Build log — 2026-07-01", "Release v0.9", "Build log — 2026-05-01",
                     "Build log — 2026-04-01" ],
                   entry_titles(feed)
    end

    # --- 3. the cap ------------------------------------------------------------------

    # SEEDED PAST THE CAP ON BOTH SIDES: the two items that must be dropped are the OLDEST, so a
    # cap applied before the sort (or not at all) is visible in both the count and the first title.
    test "the feed is capped at FEED_CAP, keeping the newest" do
      base = Time.zone.local(2026, 8, 1, 9, 0, 0)
      (CAP + 1).times { |i| add_entry!("Entry #{i}.", base + i.days) }

      get path

      doc = feed
      assert_equal CAP, doc.xpath("//xmlns:entry").size
      assert_equal "Build log — #{(base + CAP.days).strftime("%Y-%m-%d")}", entry_titles(doc).first
      refute_includes entry_titles(doc), "Build log — 2026-05-01",
                      "the fixture's own entry is the oldest of #{CAP + 2} and must fall off"
    end

    # --- 4. the content ---------------------------------------------------------------

    test "an entry's content is type=html and a script in a body never reaches the feed" do
      add_entry!("<div>Cut the <b>base</b>.<script>alert(1)</script></div>",
                 Time.zone.local(2026, 6, 1, 9, 0, 0))

      get path

      content = feed.at_xpath("//xmlns:entry/xmlns:content")
      assert_equal "html", content["type"]
      assert_includes content.text, "<b>base</b>", "Action Text's rendered markup, not plain text"
      # BOTH SPELLINGS. The raw tag would mean the feed document itself is unescaped; the escaped
      # one would still be a script the moment a reader honours `type="html"` and renders it.
      refute_includes response.body, "<script>"
      refute_includes response.body, "&lt;script&gt;"
    end

    test "a release's content carries its notes and how many files it holds" do
      release = add_release!("v2.0", Time.zone.local(2026, 6, 1, 9, 0, 0),
                             notes: "<div>Reworked the frame.</div>")
      release.files.create!(user: @user, node_id: @f[:base].node_id, name: "base.stl",
                            path: "models/base.stl", content_token: "t", size: 10)

      get path

      content = feed.at_xpath("//xmlns:entry[xmlns:title='Release v2.0']/xmlns:content").text
      assert_includes content, "Reworked the frame."
      assert_includes content, "1 file in this release."
    end

    # --- 5. visibility gates the feed exactly as it gates the page ----------------------

    test "a private project's feed is 404 and an unlisted one needs its token" do
      @project.update!(visibility: "private")
      get path
      assert_response :not_found

      @project.update!(visibility: "unlisted")
      get path
      assert_response :not_found, "without the token there is no page and no feed either"

      get path(k: @project.reload.unlisted_token)
      assert_response :success
    end

    test "every URL an unlisted feed emits carries the token" do
      @project.update!(visibility: "unlisted")
      token = @project.reload.unlisted_token
      add_release!("v1.0", Time.zone.local(2026, 6, 1, 9, 0, 0))

      get path(k: token)

      doc = feed
      hrefs = doc.xpath("//xmlns:link").map { |l| l["href"] }
      assert_equal 4, hrefs.size, "two feed links and one per item — #{hrefs.size} is vacuous (§14e)"
      hrefs.each do |href|
        assert_includes href, "k=#{token}",
                        "#{href} drops the token, so following it from a reader is a 404"
      end
    end

    # --- 6. the page advertises it ------------------------------------------------------

    test "the project page points at the feed, with the token when unlisted" do
      get public_project_path("ada", @project.slug)

      link = css_select("link[rel='alternate'][type='application/atom+xml']").first
      assert link, "a reader finds a feed through <link rel=alternate>, not by guessing the path"
      assert_equal public_feed_path("ada", @project.slug), link["href"]
      assert_equal 1, css_select("a.feed-link").size

      @project.update!(visibility: "unlisted")
      token = @project.reload.unlisted_token
      get public_project_path("ada", @project.slug, k: token)

      assert_includes css_select("link[rel='alternate'][type='application/atom+xml']").first["href"],
                      "k=#{token}"
      assert_includes css_select("a.feed-link").first["href"], "k=#{token}"
    end

    # --- 7. the anchors the feed points at actually exist -------------------------------

    # THE FEED'S LINKS AND THE PAGE'S IDS ARE ONE FACT WRITTEN IN TWO FILES, so this asserts the
    # pair rather than either half: a reader that opens an item must land ON it.
    test "every item's fragment resolves to an element on the page" do
      add_release!("v1.0", Time.zone.local(2026, 6, 1, 9, 0, 0))

      get path
      fragments = feed.xpath("//xmlns:entry/xmlns:link").map { |l| URI(l["href"]).fragment }
      assert_equal 2, fragments.size

      get public_project_path("ada", @project.slug)
      fragments.each do |fragment|
        assert_equal 1, css_select("##{fragment}").size,
                     "the feed links ##{fragment} and the page renders no such element"
      end
    end

    # --- 8. the panel layout reaches the feed (hardening, 2026-09-08; tinkerex#283) ---------
    #
    # A HIDDEN PANEL'S ITEMS ARE ABSENT FROM THE DOCUMENT, NOT MERELY OFF THE PAGE. The feed is one
    # click from the page that hides them and it is the surface a reader KEEPS, so a build log that
    # is hidden on the page and complete in the feed is the leak, not a cosmetic mismatch. The two
    # kinds are gated separately, so both single-hidden cases are driven: a gate written as one
    # condition over both panels passes whichever of the two you write on its own.

    test "hiding the build log drops its entries from the feed and leaves the releases" do
      add_release!("v1.0", Time.zone.local(2026, 6, 1, 9, 0, 0))
      @project.update!(panels: { "hidden" => %w[build_log] })

      get path

      assert_response :success
      assert_equal [ "Release v1.0" ], entry_titles(feed),
                   "the fixture's build-log entry is hidden on the page and must be gone here too"
    end

    test "hiding releases drops them from the feed and leaves the build log" do
      add_release!("v1.0", Time.zone.local(2026, 6, 1, 9, 0, 0))
      @project.update!(panels: { "hidden" => %w[releases] })

      get path

      assert_response :success
      assert_equal [ "Build log — 2026-05-01" ], entry_titles(feed)
    end

    # STILL A FEED, JUST AN EMPTY ONE. The document is not 404 and not malformed: a reader that
    # already subscribed keeps polling whatever we do, and a broken document is a reader error
    # forever where an empty one is simply nothing new. What changes is that the page stops
    # ADVERTISING it, on both surfaces at once — the visible anchor and the <link> a reader
    # auto-discovers — which is the pair that must not drift.
    test "hiding both kinds leaves valid Atom with no entries and a page that advertises no feed" do
      add_release!("v1.0", Time.zone.local(2026, 6, 1, 9, 0, 0))
      @project.update!(panels: { "hidden" => %w[build_log releases] })

      get path

      assert_response :success
      assert_equal "application/atom+xml", response.media_type
      doc = feed
      assert_equal "feed", doc.root.name, "still a parseable feed, not a truncated document"
      assert_equal "http://www.w3.org/2005/Atom", doc.root.namespace.href
      assert_equal 0, doc.xpath("//xmlns:entry").size
      assert doc.at_xpath("/xmlns:feed/xmlns:id"), "an empty feed still identifies itself"

      get public_project_path("ada", @project.slug)
      assert_equal 0, css_select("a.feed-link").size
      assert_equal 0, css_select("link[rel='alternate'][type='application/atom+xml']").size
    end

    # ONE VISIBLE KIND IS A FEED WORTH FOLLOWING, which is what makes the page's gate an OR rather
    # than an AND. Asserted on both halves of the pair, and with the OTHER panel hidden, so a gate
    # that accidentally reads "both visible" is red here while the all-visible test above stays
    # green.
    test "either kind on its own still advertises the feed on the page" do
      [ %w[build_log], %w[releases] ].each do |hidden|
        @project.update!(panels: { "hidden" => hidden })

        get public_project_path("ada", @project.slug)

        assert_equal 1, css_select("a.feed-link").size, "hiding #{hidden.first} left no feed link"
        assert_equal 1, css_select("link[rel='alternate'][type='application/atom+xml']").size
      end
    end
  end
end
