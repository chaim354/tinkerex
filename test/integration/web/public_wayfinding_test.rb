require "test_helper"
require "support/public_fixture"

module Web
  # WHAT A VISITOR'S PAGES SAY ABOUT THEMSELVES (UX audit G4 and I, 2026-11-02): a full Explore page
  # says it is the newest projects rather than reporting its cap as the total; every link has a name
  # a screen reader can read, the covers and build-log photos included, whose only content is an
  # image with `alt=""`; a card's title nests under the page's h1; every title ends " — Tinkerex";
  # and a refused request (429, 503) answers with a sentence instead of a blank page.
  #
  # PINS SHARE for PublicFixture's reason (that module's header): the project page reads real bytes
  # through the port. The list tests need no port at all.
  class PublicWayfindingTest < ActionDispatch::IntegrationTest
    include PublicFixture

    setup do
      @root = use_fresh_share_library!
      @user = make_owner!(handle: "ada")
    end

    teardown { FileLayer.reset! }

    def listed!(name, at:)
      @user.maker_projects.create!(name:, visibility: "public").tap { |p| p.update_column(:updated_at, at) }
    end

    # --- Explore's count --------------------------------------------------------------------------

    test "a full Explore page says it shows the most recent, not a total" do
      page = Public::ExploreController::PAGE
      (page + 1).times { |i| listed!(format("Project %02d", i), at: i.minutes.ago) }

      get public_explore_path
      assert_response :success
      assert_select ".project-card-grid .project-card", count: page
      assert_select ".page-head .page-title .mono", text: "Showing the #{page} most recent"
      assert_select ".page-head", text: /#{page} projects/, count: 0
    end

    test "an Explore page that holds every project counts them" do
      listed!("Desk Lamp", at: 1.day.ago)
      listed!("Bike Rack", at: 2.days.ago)

      get public_explore_path
      assert_select ".page-head .page-title .mono", text: "2 projects"
    end

    # EXACTLY PAGE IS STILL "ALL OF THEM": the extra row the controller asks for is what tells a full
    # last page from a cut-off one, and an off-by-one there would call 60 of 60 "the most recent".
    test "exactly one page of projects is counted, not called the most recent" do
      page = Public::ExploreController::PAGE
      page.times { |i| listed!(format("Project %02d", i), at: i.minutes.ago) }

      get public_explore_path
      assert_select ".page-head .page-title .mono", text: "#{page} projects"
    end

    # --- headings, names, chips, titles ------------------------------------------------------------

    test "a list card's title is an h2 under the page's h1, and its cover link is named" do
      listed!("Desk Lamp", at: 1.day.ago)

      [ public_explore_path, public_user_path("ada") ].each do |path|
        get path
        assert_select "main h1", 1
        assert_select ".project-card h2.card-title a", { text: "Desk Lamp" }, path
        assert_select ".project-card h3", { count: 0 }, path
        assert_select ".project-card a.card-cover[aria-label=?]", "Desk Lamp", { count: 1 }, path
        unnamed = css_select("main a").select { |a| a.text.strip.empty? && a["aria-label"].blank? && a["title"].blank? }
        assert_empty unnamed.map(&:to_html), "#{path} renders a link with no name"
      end
    end

    test "the chosen tag chip is marked current, the others are not" do
      @user.maker_projects.create!(name: "Desk Lamp", visibility: "public", tag_list: "lamp, laser")

      get public_explore_path(tag: "lamp")
      assert_select ".explore-chips a.tag-chip.active[aria-current=page]", text: /\Alamp/
      assert_select ".explore-chips a.tag-chip[aria-current]", 1
    end

    test "a build-log photo link and a photo tile are named by their file" do
      seed = seed_public_project!(@user)

      get public_project_path("ada", seed[:project].slug)
      assert_response :success
      assert_select ".entry-photos a.photo-cell[aria-label=?]", seed[:entry_photo].name, 1
      assert_select ".public-photos a.photo-cell[aria-label=?]", seed[:pic].name, 1
    end

    test "every public page's title ends with one separator and the product name" do
      seed = seed_public_project!(@user)
      {
        public_explore_path => "Explore — Tinkerex",
        public_user_path("ada") => "@ada — Tinkerex",
        public_project_path("ada", seed[:project].slug) => "Desk Lamp — @ada — Tinkerex",
        public_file_view_path("ada", seed[:project].slug, seed[:base].node_id) => "base.stl — Desk Lamp — @ada — Tinkerex",
        public_compose_path => "Make a docker-compose.yml — Tinkerex"
      }.each do |path, title|
        get path
        assert_response :success, path
        assert_select "head title", { text: title }, path
      end
    end

    # --- refusals ------------------------------------------------------------------------------------

    # A BLANK PAGE IS NOT AN ANSWER A VISITOR CAN READ (UX audit G4). Both refusals were `head`.
    test "a library that cannot answer is a 503 with a sentence, not an empty body" do
      seed = seed_public_project!(@user)
      FileLayer.current.define_singleton_method(:stat) { |*_a, **_k| raise FileLayer::FetchError, "unmounted" }

      get public_file_view_path("ada", seed[:project].slug, seed[:base].node_id)

      assert_response :service_unavailable
      assert_equal "text/html", response.media_type
      assert_select "body p", text: "Not available right now — try again in a moment."
      assert_select "head title", text: "Not available — Tinkerex"
      assert_not_includes response.body, "unmounted", "the port's own message reached the visitor"
      assert_not_includes response.body, "FetchError"
    end
  end
end
